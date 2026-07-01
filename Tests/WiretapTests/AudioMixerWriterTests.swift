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

        let assetDuration = try await AVURLAsset(url: outputURL).load(.duration).seconds
        XCTAssertGreaterThan(assetDuration, 0.30)
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
}
