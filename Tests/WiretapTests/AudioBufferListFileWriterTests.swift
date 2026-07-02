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

    func testFlushReportsDroppedFramesWhenReusableBufferPoolIsExhausted() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("small-pool-overflow.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.01)
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseWrite = DispatchSemaphore(value: 0)
        let writer = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format,
            bufferPoolSize: 1,
            pooledFrameCapacity: 1_024,
            writeBuffer: { audioFile, buffer in
                writeStarted.signal()
                _ = releaseWrite.wait(timeout: .now() + 2)
                try audioFile.write(from: buffer)
            }
        )

        writer.write(inputData: buffer.audioBufferList)
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        writer.write(inputData: buffer.audioBufferList)
        releaseWrite.signal()

        let result = writer.flush()

        XCTAssertNotNil(result.writeError)
        XCTAssertEqual(result.capturedFrameCount, Int64(buffer.frameLength * 2))
        XCTAssertEqual(result.droppedFrameCount, Int64(buffer.frameLength))
    }

    func testInterleavedInputReportsExactCapturedFrameCount() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("interleaved-input.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.125)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        writer?.write(inputData: buffer.audioBufferList)
        let result = writer?.flush()
        writer = nil

        XCTAssertEqual(result?.capturedFrameCount, Int64(buffer.frameLength))
        XCTAssertEqual(result?.droppedFrameCount, 0)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.125, accuracy: 0.05)
    }

    func testOversizedInputReportsDroppedFramesWithoutAllocatingFallback() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("oversized-drop.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.05)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format,
            bufferPoolSize: 2,
            pooledFrameCapacity: 128
        )

        writer?.write(inputData: buffer.audioBufferList)

        let result = writer?.flush()
        writer = nil

        XCTAssertNotNil(result?.writeError)
        XCTAssertEqual(result?.capturedFrameCount, Int64(buffer.frameLength))
        XCTAssertEqual(result?.droppedFrameCount, Int64(buffer.frameLength))
    }

    func testFlushReportsQueuedWriteFailure() throws {
        enum TestWriteError: Error {
            case failed
        }

        let outputURL = temporaryDirectory.appendingPathComponent("write-failure.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.01)
        let writer = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format,
            writeBuffer: { _, _ in throw TestWriteError.failed }
        )

        writer.write(inputData: buffer.audioBufferList)

        let result = writer.flush()

        XCTAssertNotNil(result.writeError)
        XCTAssertGreaterThan(result.capturedFrameCount, 0)
    }

    func testFlushReportsCapturedFrameCount() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("frame-count.m4a")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.02)
        let writer = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        writer.write(inputData: buffer.audioBufferList)
        writer.write(inputData: buffer.audioBufferList)

        let result = writer.flush()

        XCTAssertNil(result.writeError)
        XCTAssertEqual(result.capturedFrameCount, Int64(buffer.frameLength * 2))
        XCTAssertEqual(result.droppedFrameCount, 0)
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
        buffer.frameLength = frameCount

        if format.isInterleaved {
            let audioBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let samples = try XCTUnwrap(audioBuffers.first?.mData?.assumingMemoryBound(to: Float.self))
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate) * 0.25)
                for channel in 0..<Int(format.channelCount) {
                    samples[frame * Int(format.channelCount) + channel] = sample
                }
            }
        } else {
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for frame in 0..<Int(frameCount) {
                let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / format.sampleRate) * 0.25)
                for channel in 0..<Int(format.channelCount) {
                    channels[channel][frame] = sample
                }
            }
        }

        return buffer
    }
}
