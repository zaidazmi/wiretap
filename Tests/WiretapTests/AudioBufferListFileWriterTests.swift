import AVFoundation
import Foundation
@testable import Wiretap
import XCTest

final class AudioBufferListFileWriterTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapFileWriterTests-\(UUID().uuidString)", isDirectory: true)
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

    func testQueuedWritesFlushToReadableM4A() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("queued-writes.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.1)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        writer?.write(inputData: buffer.audioBufferList)
        writer?.write(inputData: buffer.audioBufferList)
        writer?.flush()
        writer = nil

        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        let tracks = try await asset.loadTracks(withMediaType: .audio)

        XCTAssertGreaterThan(duration, 0.15)
        XCTAssertEqual(tracks.count, 1)
    }

    private func makeToneBuffer(
        format: AVAudioFormat,
        duration: TimeInterval,
        frequency: Double = 440
    ) throws -> AVAudioPCMBuffer {
        let frameCount = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ))
        let channels = try XCTUnwrap(buffer.floatChannelData)
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate) * 0.25)
            for channel in 0..<Int(format.channelCount) {
                channels[channel][frame] = sample
            }
        }

        return buffer
    }
}
