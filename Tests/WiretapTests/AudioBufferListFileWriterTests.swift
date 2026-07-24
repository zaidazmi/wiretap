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

    func testQueuedWritesFlushToReadableCAF() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("queued-writes.caf")
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
        let outputURL = temporaryDirectory.appendingPathComponent("small-pool-overflow.caf")
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

    func testDefaultBufferPoolAbsorbsShortWriterStallWithoutDroppingFrames() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("default-pool-stall.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.01)
        let writeStarted = DispatchSemaphore(value: 0)
        let releaseFirstWrite = DispatchSemaphore(value: 0)
        let writer = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format,
            writeBuffer: { audioFile, buffer in
                if audioFile.framePosition == 0 {
                    writeStarted.signal()
                    _ = releaseFirstWrite.wait(timeout: .now() + 2)
                }
                try audioFile.write(from: buffer)
            }
        )

        writer.write(inputData: buffer.audioBufferList)
        XCTAssertEqual(writeStarted.wait(timeout: .now() + 2), .success)
        for _ in 0..<32 {
            writer.write(inputData: buffer.audioBufferList)
        }
        releaseFirstWrite.signal()

        let result = writer.flush()

        XCTAssertNil(result.writeError)
        XCTAssertEqual(result.capturedFrameCount, Int64(buffer.frameLength * 33))
        XCTAssertEqual(result.droppedFrameCount, 0)
    }

    func testInterleavedInputReportsExactCapturedFrameCount() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("interleaved-input.caf")
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

    func testLowSampleRateInterleavedInputKeepsDuration() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("low-rate-interleaved-input.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 2,
            interleaved: true
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.25)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        writer?.write(inputData: buffer.audioBufferList)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        XCTAssertEqual(result?.capturedFrameCount, Int64(buffer.frameLength))

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.25, accuracy: 0.04)
    }

    func testOversizedInputReportsDroppedFramesWithoutAllocatingFallback() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("oversized-drop.caf")
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

        let outputURL = temporaryDirectory.appendingPathComponent("write-failure.caf")
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
        let outputURL = temporaryDirectory.appendingPathComponent("frame-count.caf")
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

    func testInputFormatChangeMidStreamKeepsFileDuration() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("format-change.caf")
        let fileFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let loweredFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 2,
            interleaved: true
        ))
        let originalBuffer = try makeToneBuffer(format: fileFormat, duration: 0.25)
        let loweredBuffer = try makeToneBuffer(format: loweredFormat, duration: 0.25)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: fileFormat
        )

        writer?.write(inputData: originalBuffer.audioBufferList)
        writer?.updateInputFormat(loweredFormat)
        writer?.write(inputData: loweredBuffer.audioBufferList)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        XCTAssertEqual(
            result?.capturedFrameCount,
            Int64(originalBuffer.frameLength) + Int64(loweredBuffer.frameLength)
        )

        // Without conversion, the 16 kHz chunk would occupy only ~0.083 s of a
        // 48 kHz file and play back sped up; converted, the total stays ~0.5 s.
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)
    }

    func testRepeatedFormatTransitionsDrainEachConverterInTimelineOrder() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("repeated-format-changes.caf")
        let fileFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let bluetoothVoiceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let alternateVoiceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let first = try makeToneBuffer(format: bluetoothVoiceFormat, duration: 0.25)
        let direct = try makeToneBuffer(format: fileFormat, duration: 0.25, frequency: 660)
        let last = try makeToneBuffer(format: alternateVoiceFormat, duration: 0.25, frequency: 880)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: fileFormat,
            channelMapping: .primaryInput
        )

        writer?.write(buffer: first)
        writer?.write(buffer: direct)
        writer?.write(buffer: last)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        let file = try AVAudioFile(forReading: outputURL)
        let expectedFrames = AVAudioFramePosition(0.75 * fileFormat.sampleRate)
        XCTAssertEqual(file.length, expectedFrames, accuracy: 32)
    }

    func testPrimaryInputMappingSurvivesMonoToMultichannelVoiceChatChange() throws {
        let outputURL = temporaryDirectory.appendingPathComponent("voice-chat-format-change.caf")
        let monoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let stereoFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makePhaseOpposedBuffer(format: stereoFormat, duration: 0.2)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: monoFormat,
            channelMapping: .primaryInput
        )

        writer?.updateInputFormat(stereoFormat)
        writer?.write(inputData: buffer.audioBufferList)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        let file = try AVAudioFile(
            forReading: outputURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let output = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ))
        try file.read(into: output)
        let samples = try XCTUnwrap(output.floatChannelData?[0])
        var peak: Float = 0
        for frame in 0..<Int(output.frameLength) {
            peak = max(peak, abs(samples[frame]))
        }
        XCTAssertGreaterThan(peak, 0.20)
    }

    func testSampleTimeGapIsFilledWithSilence() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("gap-fill.caf")
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

        // 0.1 s of audio, a 0.3 s silent hole in the device timeline, then
        // another 0.1 s of audio: the file must span 0.5 s, not 0.2 s.
        writer?.write(inputData: buffer.audioBufferList, sampleTime: 0)
        writer?.write(
            inputData: buffer.audioBufferList,
            sampleTime: Float64(buffer.frameLength) + 0.3 * format.sampleRate
        )
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.02)
    }

    func testBluetoothSizedSampleTimeGapIsFilledWithSilence() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("bluetooth-gap-fill.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.01)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        // Bluetooth voice callbacks are commonly 160 frames at 16 kHz. Losing
        // one callback must preserve its 10 ms slot instead of shortening time.
        writer?.write(inputData: buffer.audioBufferList, sampleTime: 0)
        writer?.write(
            inputData: buffer.audioBufferList,
            sampleTime: Float64(buffer.frameLength * 2)
        )
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        let file = try AVAudioFile(forReading: outputURL)
        XCTAssertEqual(file.length, AVAudioFramePosition(buffer.frameLength * 3))
    }

    func testExplicitTimelineAnchorPreservesSilenceBeforeFirstAudioPacket() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("explicit-leading-gap.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.1)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        writer?.anchorTimeline(at: 0)
        writer?.write(
            inputData: buffer.audioBufferList,
            sampleTime: 0.4 * format.sampleRate
        )
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.02)
    }

    func testDeviceHandoffSilenceKeepsContinuousTimeline() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("device-handoff-gap.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.1)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format,
            channelMapping: .primaryInput
        )

        writer?.write(inputData: buffer.audioBufferList)
        writer?.appendHandoffSilence(duration: 0.2)
        writer?.write(inputData: buffer.audioBufferList)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.4, accuracy: 0.02)
    }

    func testEmptyCallbackAnchorsTimelineForLeadingSilence() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("leading-gap.caf")
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let buffer = try makeToneBuffer(format: format, duration: 0.1)
        var emptyBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: 2, mDataByteSize: 0, mData: nil)
        )
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: format
        )

        // An empty cycle at sample time 0 anchors the timeline; audio arriving
        // at 0.4 s must be preceded by 0.4 s of silence in the file.
        withUnsafePointer(to: &emptyBufferList) { pointer in
            writer?.write(inputData: pointer, sampleTime: 0)
        }
        writer?.write(inputData: buffer.audioBufferList, sampleTime: 0.4 * format.sampleRate)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.02)
    }

    func testWritePCMBufferAdoptsBufferFormat() async throws {
        let outputURL = temporaryDirectory.appendingPathComponent("buffer-format-adoption.caf")
        let fileFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))
        let deliveredFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 24_000,
            channels: 1,
            interleaved: false
        ))
        let deliveredBuffer = try makeToneBuffer(format: deliveredFormat, duration: 0.5)
        var writer: AudioBufferListFileWriter? = try AudioBufferListFileWriter(
            outputURL: outputURL,
            inputFormat: fileFormat
        )

        writer?.write(buffer: deliveredBuffer)
        let result = writer?.flush()
        writer = nil

        XCTAssertNil(result?.writeError)
        XCTAssertEqual(result?.capturedFrameCount, Int64(deliveredBuffer.frameLength))

        let asset = AVURLAsset(url: outputURL)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 0.5, accuracy: 0.05)
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

    private func makePhaseOpposedBuffer(
        format: AVAudioFormat,
        duration: TimeInterval
    ) throws -> AVAudioPCMBuffer {
        let buffer = try makeToneBuffer(format: format, duration: duration)
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            channels[1][frame] = -channels[0][frame]
        }
        return buffer
    }
}
