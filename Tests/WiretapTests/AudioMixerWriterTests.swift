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

    func testMixCombinesSourcesIntoSingleM4A() async throws {
        let systemURL = temporaryDirectory.appendingPathComponent("system.m4a")
        let micURL = temporaryDirectory.appendingPathComponent("microphone.m4a")
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

    func testMixIgnoresInputWithoutAudioTrack() async throws {
        let emptyURL = temporaryDirectory.appendingPathComponent("empty.m4a")
        let micURL = temporaryDirectory.appendingPathComponent("microphone.m4a")
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
        let micURL = temporaryDirectory.appendingPathComponent("microphone-only.m4a")
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

    func testMixHonorsInputStartOffset() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-offset.m4a")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed-offset.m4a")
        try writeTone(to: micURL, duration: 0.16, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone, startOffset: 0.24)
            ],
            outputURL: outputURL
        )

        XCTAssertGreaterThan(result.duration, 0.35)

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

    func testMixStretchesInputToTargetDurationForDriftCorrection() async throws {
        let micURL = temporaryDirectory.appendingPathComponent("microphone-drift.m4a")
        let outputURL = temporaryDirectory.appendingPathComponent("mixed-drift.m4a")
        try writeTone(to: micURL, duration: 0.16, frequency: 660)

        let result = try await AudioMixerWriter().mix(
            inputs: [
                AudioMixerInput(url: micURL, source: .microphone, targetDuration: 0.32)
            ],
            outputURL: outputURL
        )

        XCTAssertGreaterThan(result.duration, 0.28)

        let lateAmplitude = try averageAbsoluteAmplitude(
            in: outputURL,
            from: 0.24,
            duration: 0.05
        )

        XCTAssertGreaterThan(lateAmplitude, 0.02)
    }

    private func writeTone(to url: URL, duration: TimeInterval, frequency: Double) throws {
        let sampleRate = 48_000.0
        let channelCount: AVAudioChannelCount = 2
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
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate) * 0.2)
            for channel in 0..<Int(channelCount) {
                channels[channel][frame] = sample
            }
        }

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: Int(channelCount),
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
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
}
