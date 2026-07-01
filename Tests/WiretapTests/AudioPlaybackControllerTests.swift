import AVFoundation
import Foundation
@testable import Wiretap
import XCTest

final class AudioPlaybackControllerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapPlaybackTests-\(UUID().uuidString)", isDirectory: true)
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

    @MainActor
    func testToggleStartsPausesResumesAndStopsPlayback() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("playback.m4a")
        try writeTone(to: fileURL, duration: 1.0, frequency: 440)
        let recording = makeRecording(fileURL: fileURL)
        let controller = AudioPlaybackController()

        try controller.toggle(recording: recording)

        XCTAssertEqual(controller.recordingID, recording.id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.duration, 1.0, accuracy: 0.15)

        controller.seek(to: 0.5)

        XCTAssertEqual(controller.currentTime, controller.duration * 0.5, accuracy: 0.15)

        try controller.toggle(recording: recording)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.recordingID, recording.id)

        try controller.toggle(recording: recording)

        XCTAssertTrue(controller.isPlaying)

        controller.stop()

        XCTAssertNil(controller.recordingID)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
    }

    @MainActor
    func testToggleThrowsForMissingRecordingFile() {
        let recording = makeRecording(
            fileURL: temporaryDirectory.appendingPathComponent("missing.m4a")
        )
        let controller = AudioPlaybackController()

        XCTAssertThrowsError(try controller.toggle(recording: recording)) { error in
            guard case RecordingLibraryError.missingFile = error else {
                XCTFail("Expected missing file error, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testSeekClampsProgressToPlayableRange() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("seek.m4a")
        try writeTone(to: fileURL, duration: 1.0, frequency: 660)
        let recording = makeRecording(fileURL: fileURL)
        let controller = AudioPlaybackController()
        try controller.toggle(recording: recording)

        controller.seek(to: -1)

        XCTAssertEqual(controller.currentTime, 0, accuracy: 0.05)

        controller.seek(to: 2)

        XCTAssertEqual(controller.currentTime, controller.duration, accuracy: 0.05)
    }

    private func makeRecording(fileURL: URL) -> Recording {
        Recording(
            title: "Playback",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 1,
            fileURL: fileURL,
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
    }

    private func writeTone(
        to url: URL,
        duration: TimeInterval,
        frequency: Double
    ) throws {
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
