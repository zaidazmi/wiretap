import AVFoundation
import Foundation
import os.lock

final class AudioBufferListFileWriter {
    private let inputFormat: AVAudioFormat
    private let state: WriteState
    private let writeQueue: DispatchQueue
    private let writeQueueKey = DispatchSpecificKey<Bool>()
    private let bufferPool: AudioPCMBufferPool

    init(
        outputURL: URL,
        inputFormat: AVAudioFormat,
        bufferPoolSize: Int = 12,
        pooledFrameCapacity: AVAudioFrameCount = 16_384,
        writeBuffer: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { audioFile, buffer in
            try audioFile.write(from: buffer)
        }
    ) throws {
        let channelCount = max(1, Int(inputFormat.channelCount))
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        self.inputFormat = inputFormat
        self.state = WriteState(audioFile: try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        ), writeBuffer: writeBuffer)
        self.bufferPool = AudioPCMBufferPool(
            format: inputFormat,
            capacity: bufferPoolSize,
            frameCapacity: pooledFrameCapacity
        )
        self.writeQueue = DispatchQueue(
            label: "dev.zaidazmi.Wiretap.audio-file-writer.\(UUID().uuidString)",
            qos: .utility
        )
        self.writeQueue.setSpecific(key: writeQueueKey, value: true)
    }

    deinit {
        flush()
    }

    var capturedFrameCount: Int64 {
        state.capturedFrameCount
    }

    func write(inputData: UnsafePointer<AudioBufferList>) {
        switch copiedBuffer(from: inputData) {
        case let .success(pendingBuffer):
            writeQueue.async { [state, pendingBuffer] in
                defer { pendingBuffer.recycle() }
                state.write(pendingBuffer.buffer)
            }
        case let .failure(failure):
            state.recordDroppedFrames(failure.frameCount, error: failure.error)
        case nil:
            return
        }
    }

    @discardableResult
    func flush() -> AudioFileWriterFlushResult {
        guard DispatchQueue.getSpecific(key: writeQueueKey) != true else {
            return state.flushResult
        }

        writeQueue.sync {}
        return state.flushResult
    }

    private func copiedBuffer(from inputData: UnsafePointer<AudioBufferList>) -> PendingAudioBufferResult? {
        guard let firstBuffer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        ).first else { return nil }

        let streamDescription = inputFormat.streamDescription.pointee
        guard streamDescription.mBytesPerFrame > 0 else { return nil }

        let bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        let frameLength = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameLength > 0 else { return nil }

        guard frameLength <= bufferPool.frameCapacity else {
            return .failure(PendingAudioBufferFailure(
                frameCount: frameLength,
                error: AudioBufferListFileWriterError.bufferExceedsPoolCapacity(
                    frameCount: frameLength,
                    capacity: bufferPool.frameCapacity
                )
            ))
        }

        guard let pendingBuffer = bufferPool.borrow(frameLength: frameLength) else {
            return .failure(PendingAudioBufferFailure(
                frameCount: frameLength,
                error: AudioBufferListFileWriterError.bufferPoolExhausted(frameCount: frameLength)
            ))
        }

        copy(inputData: inputData, frameLength: frameLength, into: pendingBuffer.buffer)
        return .success(pendingBuffer)
    }

    private func copy(
        inputData: UnsafePointer<AudioBufferList>,
        frameLength: AVAudioFrameCount,
        into copiedBuffer: AVAudioPCMBuffer
    ) {
        copiedBuffer.frameLength = frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copiedBuffer.mutableAudioBufferList
        )

        for destination in destinationBuffers {
            guard let destinationData = destination.mData else { continue }
            memset(destinationData, 0, Int(destination.mDataByteSize))
        }

        for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
            let source = sourceBuffers[index]
            let destination = destinationBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destination.mData
            else { continue }

            let byteCount = min(Int(source.mDataByteSize), Int(destination.mDataByteSize))
            memcpy(destinationData, sourceData, byteCount)
            destinationBuffers[index].mDataByteSize = UInt32(byteCount)
        }
    }
}

private enum PendingAudioBufferResult {
    case success(PendingAudioBuffer)
    case failure(PendingAudioBufferFailure)
}

private struct PendingAudioBufferFailure {
    var frameCount: AVAudioFrameCount
    var error: Error
}

struct AudioFileWriterFlushResult {
    var capturedFrameCount: Int64
    var droppedFrameCount: Int64 = 0
    var writeError: Error?
}

enum AudioBufferListFileWriterError: LocalizedError {
    case bufferPoolExhausted(frameCount: AVAudioFrameCount)
    case bufferExceedsPoolCapacity(frameCount: AVAudioFrameCount, capacity: AVAudioFrameCount)

    var errorDescription: String? {
        switch self {
        case let .bufferPoolExhausted(frameCount):
            "Wiretap dropped \(frameCount) audio frames because the capture buffer pool was exhausted."
        case let .bufferExceedsPoolCapacity(frameCount, capacity):
            "Wiretap dropped \(frameCount) audio frames because the capture buffer exceeded the pool capacity of \(capacity) frames."
        }
    }
}

private final class AudioPCMBufferPool: @unchecked Sendable {
    private let format: AVAudioFormat
    let frameCapacity: AVAudioFrameCount
    private var lock = os_unfair_lock_s()
    private var buffers: [AVAudioPCMBuffer]

    init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
        let normalizedFrameCapacity = max(1, frameCapacity)
        self.format = format
        self.frameCapacity = normalizedFrameCapacity
        self.buffers = (0..<max(0, capacity)).compactMap { _ in
            AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: normalizedFrameCapacity
            )
        }
    }

    func borrow(frameLength: AVAudioFrameCount) -> PendingAudioBuffer? {
        guard frameLength <= frameCapacity,
              os_unfair_lock_trylock(&lock)
        else { return nil }

        defer { os_unfair_lock_unlock(&lock) }
        guard let buffer = buffers.popLast() else { return nil }

        return PendingAudioBuffer(buffer: buffer, recycleHandler: { [weak self, buffer] in
            self?.recycle(buffer)
        })
    }

    private func recycle(_ buffer: AVAudioPCMBuffer) {
        buffer.frameLength = 0
        os_unfair_lock_lock(&lock)
        buffers.append(buffer)
        os_unfair_lock_unlock(&lock)
    }
}

private final class WriteState: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let writeBuffer: (AVAudioFile, AVAudioPCMBuffer) throws -> Void
    private let lock = NSLock()
    private var storedWriteError: Error?
    private var storedCapturedFrameCount: Int64 = 0
    private var storedDroppedFrameCount: Int64 = 0

    init(
        audioFile: AVAudioFile,
        writeBuffer: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void
    ) {
        self.audioFile = audioFile
        self.writeBuffer = writeBuffer
    }

    var flushResult: AudioFileWriterFlushResult {
        lock.lock()
        defer { lock.unlock() }
        return AudioFileWriterFlushResult(
            capturedFrameCount: storedCapturedFrameCount,
            droppedFrameCount: storedDroppedFrameCount,
            writeError: storedWriteError
        )
    }

    var capturedFrameCount: Int64 {
        lock.lock()
        defer { lock.unlock() }
        return storedCapturedFrameCount
    }

    func write(_ buffer: AVAudioPCMBuffer) {
        recordCapturedFrames(buffer.frameLength)

        do {
            try writeBuffer(audioFile, buffer)
        } catch {
            recordWriteError(error)
        }
    }

    func recordDroppedFrames(_ frameCount: AVAudioFrameCount, error: Error) {
        lock.lock()
        storedCapturedFrameCount += Int64(frameCount)
        storedDroppedFrameCount += Int64(frameCount)
        if storedWriteError == nil {
            storedWriteError = error
        }
        lock.unlock()
    }

    private func recordCapturedFrames(_ frameCount: AVAudioFrameCount) {
        lock.lock()
        storedCapturedFrameCount += Int64(frameCount)
        lock.unlock()
    }

    private func recordWriteError(_ error: Error) {
        lock.lock()
        if storedWriteError == nil {
            storedWriteError = error
        }
        lock.unlock()
    }
}

private final class PendingAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    private let recycleHandler: (() -> Void)?

    init(buffer: AVAudioPCMBuffer, recycleHandler: (() -> Void)? = nil) {
        self.buffer = buffer
        self.recycleHandler = recycleHandler
    }

    func recycle() {
        recycleHandler?()
    }
}
