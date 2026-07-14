import AVFoundation
import Foundation
@testable import Wiretap
import XCTest

final class AudioMixerWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapMixerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    func testSampleLimiterScalesEntireBlockWhenPeakExceedsCeiling() throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2),
            let channels = buffer.floatChannelData
        else {
            XCTFail("Could not create limiter test buffer")
            return
        }

        buffer.frameLength = 2
        channels[0][0] = 1.2
        channels[0][1] = -0.6
        channels[1][0] = 0.4
        channels[1][1] = -2.0

        AudioSampleLimiter(ceiling: 0.95).apply(to: buffer)

        XCTAssertEqual(channels[0][0], 0.57, accuracy: 0.001)
        XCTAssertEqual(channels[0][1], -0.285, accuracy: 0.001)
        XCTAssertEqual(channels[1][0], 0.19, accuracy: 0.001)
        XCTAssertEqual(channels[1][1], -0.95, accuracy: 0.001)
    }

    func testPrimaryChannelExtractionDoesNotCancelPhaseOpposedMicrophoneArray() throws {
        let inputURL = temporaryDirectory.appendingPathComponent("three-channel-microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("primary-microphone.caf")
        try writePhaseOpposedArrayTone(to: inputURL, duration: 0.2)

        let metrics = try OfflineMicrophoneProcessor().extractPrimaryChannel(
            inputURL: inputURL,
            outputURL: outputURL
        )

        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(outputFile.processingFormat.channelCount, 1)
        XCTAssertEqual(outputFile.length, 9_600)
        XCTAssertGreaterThan(metrics.peak, 0.15)
        XCTAssertGreaterThan(metrics.rootMeanSquare, 0.10)
        XCTAssertGreaterThan(metrics.nonzeroSampleCount, 9_000)
    }

    func testOfflineSoundIsolationPreservesSourceDuration() throws {
        let inputURL = temporaryDirectory.appendingPathComponent("speaker-microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("isolated-microphone.caf")
        try writeTone(
            to: inputURL,
            duration: 0.2,
            frequency: 180,
            amplitude: 0.2,
            channelCount: 1
        )

        let result = try OfflineMicrophoneProcessor().applySoundIsolation(
            inputURL: inputURL,
            outputURL: outputURL
        )

        let outputFile = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(outputFile.processingFormat.channelCount, 1)
        XCTAssertEqual(outputFile.length, 9_600)
        XCTAssertEqual(result.rawMetrics.sampleCount, 9_600)
        XCTAssertEqual(result.processedMetrics.sampleCount, 9_600)
    }

    func testMixCombinesSourcesIntoSingleM4A() async throws {
        let systemURL = temporaryDirectory.appendingPathComponent("system.caf")
        let micURL = temporaryDirectory.appendingPathComponent("microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed.m4a")
        try writeTone(to: systemURL, duration: 0.35, frequency: 440)
        try writeTone(to: micURL, duration: 0.2, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: systemURL, source: .systemAudio),
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.sources, [.systemAudio, .microphone])
        XCTAssertGreaterThan(result.duration, 0.30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let asset = AVURLAsset(url: outputURL)
        let assetDuration = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(assetDuration, 0.30)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let formatDescriptions = try await tracks[0].load(.formatDescriptions)
        let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescriptions[0]
        )!.pointee
        XCTAssertEqual(streamDescription.mSampleRate, 48_000, accuracy: 1)
        XCTAssertEqual(streamDescription.mChannelsPerFrame, 2)
    }

    func testMixLimitsSummedPeaks() async throws {
        let systemURL = temporaryDirectory.appendingPathComponent("loud-system.caf")
        let micURL = temporaryDirectory.appendingPathComponent("loud-microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("limited.m4a")
        try writeTone(to: systemURL, duration: 0.2, frequency: 440, amplitude: 0.95)
        try writeTone(to: micURL, duration: 0.2, frequency: 440, amplitude: 0.95)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: systemURL, source: .systemAudio),
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.duration, 0.2, accuracy: 0.03)
        XCTAssertLessThanOrEqual(try peakAbsoluteAmplitude(in: outputURL), 1.02)
        XCTAssertGreaterThan(
            try averageAbsoluteAmplitude(in: outputURL, from: 0.02, duration: 0.12),
            0.30
        )
    }

    func testMixConvertsInputTo48kStereoOutput() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-44k-mono.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("converted-output.m4a")
        try writeTone(
            to: micURL,
            duration: 0.24,
            frequency: 330,
            sampleRate: 44_100,
            channelCount: 1
        )

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.sources, [.microphone])
        XCTAssertEqual(result.duration, 0.24, accuracy: 0.03)

        let streamDescription = try await audioStreamDescription(for: outputURL)
        XCTAssertEqual(streamDescription.mSampleRate, 48_000, accuracy: 1)
        XCTAssertEqual(streamDescription.mChannelsPerFrame, 2)
        XCTAssertGreaterThan(
            try averageAbsoluteAmplitude(in: outputURL, from: 0.04, duration: 0.12),
            0.02
        )
    }

    func testMixBoostsQuietMicrophoneInputByDefault() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("quiet-microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("boosted-microphone.m4a")
        try writeTone(to: micURL, duration: 0.24, frequency: 660, amplitude: 0.02)

        _ = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertGreaterThan(
            try averageAbsoluteAmplitude(in: outputURL, from: 0.04, duration: 0.12),
            0.025
        )
        XCTAssertLessThanOrEqual(try peakAbsoluteAmplitude(in: outputURL), 0.12)
    }

    func testMixCanKeepMicrophoneAtUnityGain() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("unboosted-microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("unboosted-output.m4a")
        try writeTone(to: micURL, duration: 0.24, frequency: 660, amplitude: 0.08)

        _ = try await AudioMixerWriter(microphoneGain: 1).mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertLessThan(
            try averageAbsoluteAmplitude(in: outputURL, from: 0.04, duration: 0.12),
            0.08
        )
    }

    func testMixIgnoresInputWithoutAudioTrack() async throws {
        let emptyURL = temporaryDirectory.appendingPathComponent("empty.m4a")
        let micURL = temporaryDirectory.appendingPathComponent("microphone.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed.m4a")
        try Data().write(to: emptyURL)
        try writeTone(to: micURL, duration: 0.2, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: emptyURL, source: .systemAudio),
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.sources, [.microphone])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
    }

    func testMixIgnoresMissingOffsetInputWhenCalculatingDuration() async throws {
        let missingURL = temporaryDirectory.appendingPathComponent("missing-system.m4a")
        let micURL = temporaryDirectory.appendingPathComponent("microphone-only.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("microphone-only-output.m4a")
        try writeTone(to: micURL, duration: 0.2, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: missingURL, source: .systemAudio, startOffset: 2),
                AudioMixerInput(url: micURL, source: .microphone)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.sources, [.microphone])
        XCTAssertLessThan(result.duration, 0.6)
    }

    func testMixDurationMatchesOffsetTimeline() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-timeline.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed-timeline.m4a")
        try writeTone(to: micURL, duration: 0.16, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone, startOffset: 0.24)
            ],
            outputURL: outputURL
        )

        XCTAssertEqual(result.duration, 0.40, accuracy: 0.03)
    }

    func testMixHonorsInputStartOffset() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-offset.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed-offset.m4a")
        try writeTone(to: micURL, duration: 0.16, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone, startOffset: 0.24)
            ],
            outputURL: outputURL
        )

        XCTAssertGreaterThan(result.duration, 0.35)
        XCTAssertLessThan(result.duration, 0.45)

        let initialAmplitude = try averageAbsoluteAmplitude(
            in: outputURL,
            from: 0.05,
            duration: 0.08
        )
        let activeAmplitude = try averageAbsoluteAmplitude(
            in: outputURL,
            from: 0.30,
            duration: 0.08
        )

        XCTAssertLessThan(initialAmplitude, 0.01)
        XCTAssertGreaterThan(activeAmplitude, 0.02)
    }

    func testMixPadsToTargetDurationWithoutSlowingInput() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-drift.caf")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed-drift.m4a")
        try writeTone(to: micURL, duration: 0.16, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone, targetDuration: 0.32)
            ],
            outputURL: outputURL
        )

        XCTAssertGreaterThan(result.duration, 0.28)
        XCTAssertEqual(result.duration, 0.32, accuracy: 0.03)

        let activeAmplitude = try averageAbsoluteAmplitude(
            in: outputURL,
            from: 0.06,
            duration: 0.05
        )
        let paddedAmplitude = try averageAbsoluteAmplitude(
            in: outputURL,
            from: 0.24,
            duration: 0.05
        )

        XCTAssertGreaterThan(activeAmplitude, 0.02)
        XCTAssertLessThan(paddedAmplitude, 0.01)
    }

    private func writeTone(
        to url: URL,
        duration: TimeInterval,
        frequency: Double,
        amplitude: Double = 0.2,
        sampleRate: Double = 48_000.0,
        channelCount: AVAudioChannelCount = 2
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: channelCount,
            interleaved: false
        ) else {
            XCTFail("Could not create test audio format")
            return
        }

        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else {
            XCTFail("Could not create test audio buffer")
            return
        }

        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * amplitude)
            for channel in 0..<Int(channelCount) {
                channels[channel][frame] = sample
            }
        }

        let settings: [String: Any]
        if url.pathExtension.lowercased() == "caf" {
            var pcmSettings = format.settings
            pcmSettings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            pcmSettings[AVSampleRateKey] = sampleRate
            pcmSettings[AVNumberOfChannelsKey] = Int(channelCount)
            pcmSettings[AVLinearPCMIsNonInterleaved] = false
            settings = pcmSettings
        } else {
            settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: Int(channelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func writePhaseOpposedArrayTone(to url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        let layoutTag = kAudioChannelLayoutTag_DiscreteInOrder | 3
        guard let layout = AVAudioChannelLayout(layoutTag: layoutTag) else {
            XCTFail("Could not create microphone-array test format")
            return
        }
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channelLayout: layout
        )
        let frameCount = AVAudioFrameCount(sampleRate * duration)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount),
              let channels = buffer.floatChannelData
        else {
            XCTFail("Could not create microphone-array test buffer")
            return
        }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * 330 * Double(frame) / sampleRate) * 0.2)
            channels[0][frame] = sample
            channels[1][frame] = -sample
            channels[2][frame] = 0
        }

        var settings = format.settings
        settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func averageAbsoluteAmplitude(
        in url: URL,
        from startTime: TimeInterval,
        duration: TimeInterval
    ) throws -> Float {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Could not create read buffer")
            return 0
        }

        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return 0 }

        let sampleRate = file.processingFormat.sampleRate
        let startFrame = max(0, Int(startTime * sampleRate))
        let frameCount = max(1, Int(duration * sampleRate))
        let endFrame = min(Int(buffer.frameLength), startFrame + frameCount)
        guard startFrame < endFrame else { return 0 }

        var total: Float = 0
        var sampleCount = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in startFrame..<endFrame {
                total += abs(channelData[channel][frame])
                sampleCount += 1
            }
        }

        return sampleCount > 0 ? total / Float(sampleCount) : 0
    }

    private func peakAbsoluteAmplitude(in url: URL) throws -> Float {
        let file = try AVAudioFile(
            forReading: url,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            XCTFail("Could not create read buffer")
            return 0
        }

        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData else { return 0 }

        var peak: Float = 0
        for channel in 0..<Int(buffer.format.channelCount) {
            for frame in 0..<Int(buffer.frameLength) {
                peak = max(peak, abs(channelData[channel][frame]))
            }
        }

        return peak
    }

    private func audioStreamDescription(for url: URL) async throws -> AudioStreamBasicDescription {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let formatDescriptions = try await track.load(.formatDescriptions)
        return CMAudioFormatDescriptionGetStreamBasicDescription(
            formatDescriptions[0]
        )!.pointee
    }
}
