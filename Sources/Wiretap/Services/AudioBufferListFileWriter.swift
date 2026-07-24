import AVFoundation
import Foundation
import os.lock

final class AudioBufferListFileWriter {
    private let state: WriteState
    private let writeQueue: DispatchQueue
    private let writeQueueKey = DispatchSpecificKey<Bool>()
    private let bufferPoolSize: Int
    private let pooledFrameCapacity: AVAudioFrameCount
    private let logger = WiretapLog.capture
    private var inputLock = os_unfair_lock_s()
    private var currentInputFormat: AVAudioFormat
    private var currentBufferPool: AudioPCMBufferPool
    // Device sample time expected for the next callback. Process taps deliver
    // nothing while no app renders audio, so the file timeline must be rebuilt
    // by filling those gaps with silence.
    private var expectedNextSampleTime: Float64?
    // Device sample clocks are unrelated across route and format changes. Host
    // time remains continuous, so keep the end of the last delivered buffer as
    // the authoritative handoff boundary.
    private var lastBufferEndUptime: TimeInterval?
    private var pendingDiscontinuityStartUptime: TimeInterval?

    // Ignore sub-frame timestamp jitter and absurd jumps that indicate a
    // clock-domain reset rather than real silence. A fixed 512-frame threshold
    // loses real gaps from Bluetooth voice streams, whose callbacks can be much
    // smaller than 512 frames.
    private static let minimumGapFrames: Float64 = 1
    private static let maximumGapSeconds: Float64 = 6 * 60 * 60

    init(
        outputURL: URL,
        inputFormat: AVAudioFormat,
        channelMapping: CaptureChannelMapping = .automatic,
        // VoiceProcessingIO normally delivers 512-frame buffers. Keep more than
        // one second of reusable headroom so a short disk or scheduler stall
        // cannot force the real-time callback to drop microphone audio.
        bufferPoolSize: Int = 64,
        pooledFrameCapacity: AVAudioFrameCount = 16_384,
        writeBuffer: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void = { audioFile, buffer in
            try audioFile.write(from: buffer)
        }
    ) throws {
        let outputSettings = Self.linearPCMSettings(for: inputFormat)

        self.currentInputFormat = inputFormat
        self.state = WriteState(
            audioFile: try AVAudioFile(
                forWriting: outputURL,
                settings: outputSettings,
                commonFormat: inputFormat.commonFormat,
                interleaved: inputFormat.isInterleaved
            ),
            channelMapping: channelMapping,
            writeBuffer: writeBuffer
        )
        self.bufferPoolSize = bufferPoolSize
        self.pooledFrameCapacity = pooledFrameCapacity
        self.currentBufferPool = AudioPCMBufferPool(
            format: inputFormat,
            capacity: bufferPoolSize,
            frameCapacity: pooledFrameCapacity
        )
        self.writeQueue = DispatchQueue(
            label: "dev.zaidazmi.Wiretap.audio-file-writer.\(UUID().uuidString)",
            qos: .userInitiated
        )
        self.writeQueue.setSpecific(key: writeQueueKey, value: true)
    }

    deinit {
        flush()
    }

    var capturedFrameCount: Int64 {
        state.capturedFrameCount
    }

    /// Re-interpret subsequent `write(inputData:)` calls with a new stream format.
    /// Devices can change sample rate mid-capture (a Bluetooth headset dropping
    /// from A2DP to HFP when its microphone activates); buffers that no longer
    /// match the file's format are resampled before writing so the file keeps
    /// playing at the correct speed.
    func updateInputFormat(
        _ newFormat: AVAudioFormat,
        at uptime: TimeInterval? = nil
    ) {
        os_unfair_lock_lock(&inputLock)
        let previousFormat = currentInputFormat
        os_unfair_lock_unlock(&inputLock)
        guard !audioFormatsMatch(previousFormat, newFormat) else { return }

        let newPool = AudioPCMBufferPool(
            format: newFormat,
            capacity: bufferPoolSize,
            frameCapacity: pooledFrameCapacity
        )
        os_unfair_lock_lock(&inputLock)
        currentInputFormat = newFormat
        currentBufferPool = newPool
        beginInputDiscontinuityLocked(at: resolvedUptime(uptime))
        expectedNextSampleTime = nil
        os_unfair_lock_unlock(&inputLock)
        logger.info(
            "Capture input format changed from=\(WiretapLog.audioFormatSummary(previousFormat), privacy: .public) to=\(WiretapLog.audioFormatSummary(newFormat), privacy: .public); converting to keep file format"
        )
    }

    /// Marks the boundary between devices whose sample clocks cannot be
    /// compared. The next real buffer fills the entire host-time gap, including
    /// default-device notification coalescing and IOProc startup latency.
    func beginInputDiscontinuity(at uptime: TimeInterval? = nil) {
        os_unfair_lock_lock(&inputLock)
        beginInputDiscontinuityLocked(at: resolvedUptime(uptime))
        expectedNextSampleTime = nil
        os_unfair_lock_unlock(&inputLock)
    }

    /// Keeps the output timeline stable while capture is rebound between two
    /// devices whose sample clocks are unrelated. Call this before starting the
    /// replacement IOProc so the silence is ordered between old and new buffers.
    func appendHandoffSilence(duration: TimeInterval) {
        guard duration.isFinite, duration > 0 else { return }

        os_unfair_lock_lock(&inputLock)
        let format = currentInputFormat
        expectedNextSampleTime = nil
        pendingDiscontinuityStartUptime = nil
        os_unfair_lock_unlock(&inputLock)

        let frameCount = Int64((duration * format.sampleRate).rounded())
        guard frameCount > 0 else { return }
        writeQueue.async { [state] in
            state.writeSilence(frameCount: frameCount, format: format)
        }
    }

    /// Establishes the capture clock's file-timeline origin before the first
    /// audio buffer arrives. ScreenCaptureKit can omit audio callbacks while
    /// the system is silent, so without an explicit origin the first audible
    /// packet would be shifted to the beginning of the recording.
    func anchorTimeline(at sampleTime: Float64) {
        guard sampleTime.isFinite else { return }
        anchorTimelineIfNeeded(at: sampleTime)
    }

    func write(
        buffer: AVAudioPCMBuffer,
        sampleTime: Float64? = nil,
        bufferStartUptime: TimeInterval? = nil
    ) {
        updateInputFormat(buffer.format, at: bufferStartUptime)
        write(
            inputData: buffer.audioBufferList,
            sampleTime: sampleTime,
            bufferStartUptime: bufferStartUptime
        )
    }

    func write(inputData: UnsafePointer<AudioBufferList>) {
        write(inputData: inputData, sampleTime: nil)
    }

    func write(
        inputData: UnsafePointer<AudioBufferList>,
        sampleTime: Float64?,
        bufferStartUptime: TimeInterval? = nil
    ) {
        os_unfair_lock_lock(&inputLock)
        let inputFormat = currentInputFormat
        let bufferPool = currentBufferPool
        os_unfair_lock_unlock(&inputLock)

        switch copiedBuffer(from: inputData, inputFormat: inputFormat, bufferPool: bufferPool) {
        case let .success(pendingBuffer):
            let silenceFrames = advanceTimeline(
                to: sampleTime,
                frameLength: pendingBuffer.buffer.frameLength,
                sampleRate: inputFormat.sampleRate,
                bufferStartUptime: bufferStartUptime
            )
            if silenceFrames > 0 {
                writeQueue.async { [state] in
                    state.writeSilence(frameCount: silenceFrames, format: inputFormat)
                }
            }
            writeQueue.async { [state, pendingBuffer] in
                defer { pendingBuffer.recycle() }
                state.write(pendingBuffer.buffer)
            }
        case let .failure(failure):
            state.recordDroppedFrames(failure.frameCount, error: failure.error)
        case nil:
            // No usable audio in this cycle; anchor the timeline so the gap
            // until the first real buffer can be measured and filled.
            anchorTimelineIfNeeded(at: sampleTime)
            return
        }
    }

    /// Returns how many silence frames must be written before the current
    /// buffer to keep the file aligned with the device clock.
    private func advanceTimeline(
        to sampleTime: Float64?,
        frameLength: AVAudioFrameCount,
        sampleRate: Double,
        bufferStartUptime: TimeInterval?
    ) -> Int64 {
        let duration = TimeInterval(frameLength) / sampleRate
        let observedStartUptime = resolvedUptime(bufferStartUptime) - (
            bufferStartUptime == nil ? duration : 0
        )

        os_unfair_lock_lock(&inputLock)
        defer { os_unfair_lock_unlock(&inputLock) }

        let discontinuityStartUptime = pendingDiscontinuityStartUptime
        pendingDiscontinuityStartUptime = nil
        lastBufferEndUptime = observedStartUptime + duration

        let expected = expectedNextSampleTime
        if let sampleTime {
            expectedNextSampleTime = sampleTime + Float64(frameLength)
        }

        if let discontinuityStartUptime {
            let gap = ((observedStartUptime - discontinuityStartUptime) * sampleRate).rounded()
            guard gap >= Self.minimumGapFrames,
                  gap <= Self.maximumGapSeconds * sampleRate
            else { return 0 }

            return Int64(gap)
        }

        guard let sampleTime, let expected else { return 0 }

        let gap = (sampleTime - expected).rounded()
        guard gap >= Self.minimumGapFrames,
              gap <= Self.maximumGapSeconds * sampleRate
        else { return 0 }

        return Int64(gap)
    }

    private func beginInputDiscontinuityLocked(at uptime: TimeInterval) {
        guard pendingDiscontinuityStartUptime == nil else { return }
        pendingDiscontinuityStartUptime = lastBufferEndUptime ?? uptime
    }

    private func resolvedUptime(_ uptime: TimeInterval?) -> TimeInterval {
        if let uptime, uptime.isFinite, uptime >= 0 {
            return uptime
        }

        return ProcessInfo.processInfo.systemUptime
    }

    private func anchorTimelineIfNeeded(at sampleTime: Float64?) {
        guard let sampleTime else { return }

        os_unfair_lock_lock(&inputLock)
        if expectedNextSampleTime == nil {
            expectedNextSampleTime = sampleTime
        }
        os_unfair_lock_unlock(&inputLock)
    }

    @discardableResult
    func flush() -> AudioFileWriterFlushResult {
        guard DispatchQueue.getSpecific(key: writeQueueKey) != true else {
            state.finishConversion()
            return state.flushResult
        }

        writeQueue.sync { state.finishConversion() }
        return state.flushResult
    }

    private func copiedBuffer(
        from inputData: UnsafePointer<AudioBufferList>,
        inputFormat: AVAudioFormat,
        bufferPool: AudioPCMBufferPool
    ) -> PendingAudioBufferResult? {
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let bytesPerFrame = inputFormat.streamDescription.pointee.mBytesPerFrame
        guard bytesPerFrame > 0 else { return nil }

        let frameLength = sourceBuffers
            .filter { $0.mData != nil && $0.mDataByteSize > 0 }
            .map { AVAudioFrameCount($0.mDataByteSize / bytesPerFrame) }
            .min() ?? 0
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

        copy(
            sourceBuffers: sourceBuffers,
            frameLength: frameLength,
            into: pendingBuffer.buffer
        )
        return .success(pendingBuffer)
    }

    private static func linearPCMSettings(for inputFormat: AVAudioFormat) -> [String: Any] {
        var settings = inputFormat.settings
        settings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
        settings[AVSampleRateKey] = inputFormat.sampleRate
        settings[AVNumberOfChannelsKey] = max(1, Int(inputFormat.channelCount))
        settings[AVLinearPCMIsNonInterleaved] = false
        return settings
    }

    private func copy(
        sourceBuffers: UnsafeMutableAudioBufferListPointer,
        frameLength: AVAudioFrameCount,
        into copiedBuffer: AVAudioPCMBuffer
    ) {
        copiedBuffer.frameLength = frameLength
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

enum CaptureChannelMapping: Sendable, Equatable {
    case automatic
    case primaryInput
}

private func audioFormatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
    lhs.sampleRate == rhs.sampleRate
        && lhs.channelCount == rhs.channelCount
        && lhs.commonFormat == rhs.commonFormat
        && lhs.isInterleaved == rhs.isInterleaved
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
    case formatConversionFailed

    var errorDescription: String? {
        switch self {
        case let .bufferPoolExhausted(frameCount):
            "Wiretap dropped \(frameCount) audio frames because the capture buffer pool was exhausted."
        case let .bufferExceedsPoolCapacity(frameCount, capacity):
            "Wiretap dropped \(frameCount) audio frames because the capture buffer exceeded the pool capacity of \(capacity) frames."
        case .formatConversionFailed:
            "Wiretap could not convert captured audio to the recording's file format."
        }
    }
}

private final class AudioPCMBufferPool: @unchecked Sendable {
    private let format: AVAudioFormat
    let frameCapacity: AVAudioFrameCount
    private var lock = os_unfair_lock_s()
    private var buffers: [PendingAudioBuffer]

    init(format: AVAudioFormat, capacity: Int, frameCapacity: AVAudioFrameCount) {
        let normalizedFrameCapacity = max(1, frameCapacity)
        self.format = format
        self.frameCapacity = normalizedFrameCapacity
        self.buffers = []
        self.buffers.reserveCapacity(max(0, capacity))

        for _ in 0..<max(0, capacity) {
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: normalizedFrameCapacity
            ) else { continue }

            let pendingBuffer = PendingAudioBuffer(buffer: buffer)
            pendingBuffer.pool = self
            buffers.append(pendingBuffer)
        }
    }

    func borrow(frameLength: AVAudioFrameCount) -> PendingAudioBuffer? {
        guard frameLength <= frameCapacity,
              os_unfair_lock_trylock(&lock)
        else { return nil }

        defer { os_unfair_lock_unlock(&lock) }
        guard let pendingBuffer = buffers.popLast() else { return nil }
        pendingBuffer.buffer.frameLength = frameLength
        return pendingBuffer
    }

    fileprivate func recycle(_ pendingBuffer: PendingAudioBuffer) {
        pendingBuffer.buffer.frameLength = 0
        os_unfair_lock_lock(&lock)
        buffers.append(pendingBuffer)
        os_unfair_lock_unlock(&lock)
    }
}

private final class WriteState: @unchecked Sendable {
    private let audioFile: AVAudioFile
    private let writeBuffer: (AVAudioFile, AVAudioPCMBuffer) throws -> Void
    private let channelMapping: CaptureChannelMapping
    private let lock = NSLock()
    private var storedWriteError: Error?
    private var storedCapturedFrameCount: Int64 = 0
    private var storedDroppedFrameCount: Int64 = 0
    // Only touched from the serial write queue.
    private var converter: AVAudioConverter?

    init(
        audioFile: AVAudioFile,
        channelMapping: CaptureChannelMapping,
        writeBuffer: @escaping (AVAudioFile, AVAudioPCMBuffer) throws -> Void
    ) {
        self.audioFile = audioFile
        self.channelMapping = channelMapping
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

    func write(_ buffer: AVAudioPCMBuffer, countsAsCaptured: Bool = true) {
        if countsAsCaptured {
            recordCapturedFrames(buffer.frameLength)
        }

        do {
            if audioFormatsMatch(buffer.format, audioFile.processingFormat) {
                // A converter can retain delayed output. Drain it before a
                // direct-format buffer so converted audio cannot be appended
                // later, out of timeline order.
                try drainConversion()
                try writeBuffer(audioFile, buffer)
            } else {
                try writeConverted(buffer)
            }
        } catch {
            recordWriteError(error)
        }
    }

    func writeSilence(frameCount: Int64, format: AVAudioFormat) {
        let chunkCapacity: AVAudioFrameCount = 16_384
        guard frameCount > 0,
              let silenceBuffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: chunkCapacity
              )
        else { return }

        let silenceBuffers = UnsafeMutableAudioBufferListPointer(
            silenceBuffer.mutableAudioBufferList
        )

        var remaining = frameCount
        while remaining > 0 {
            let chunk = AVAudioFrameCount(min(remaining, Int64(chunkCapacity)))
            silenceBuffer.frameLength = chunk
            for buffer in silenceBuffers {
                guard let data = buffer.mData else { continue }
                memset(data, 0, Int(buffer.mDataByteSize))
            }
            write(silenceBuffer, countsAsCaptured: false)
            remaining -= Int64(chunk)
        }
    }

    // The converter pipelines internally and holds back output until more
    // input arrives; drain it at the end so the file keeps its tail.
    func finishConversion() {
        do {
            try drainConversion()
        } catch {
            recordWriteError(error)
        }
    }

    private func drainConversion() throws {
        guard let converter else { return }
        self.converter = nil

        let targetFormat = audioFile.processingFormat
        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 8_192
            ) else {
                throw AudioBufferListFileWriterError.formatConversionFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                inputStatus.pointee = .endOfStream
                return nil
            }

            switch status {
            case .haveData:
                if output.frameLength > 0 {
                    try writeBuffer(audioFile, output)
                }
            case .inputRanDry, .endOfStream:
                if output.frameLength > 0 {
                    try writeBuffer(audioFile, output)
                }
                return
            case .error:
                throw conversionError ?? AudioBufferListFileWriterError.formatConversionFailed
            @unknown default:
                return
            }
        }
    }

    private func writeConverted(_ buffer: AVAudioPCMBuffer) throws {
        let targetFormat = audioFile.processingFormat
        if let converter, !audioFormatsMatch(converter.inputFormat, buffer.format) {
            try drainConversion()
        }
        if converter == nil {
            converter = AVAudioConverter(from: buffer.format, to: targetFormat)
            configureChannelMapping(
                converter,
                inputFormat: buffer.format,
                outputFormat: targetFormat
            )
        }
        guard let converter else {
            throw AudioBufferListFileWriterError.formatConversionFailed
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        let feed = ConverterFeed(buffer: buffer)

        while true {
            guard let output = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: capacity
            ) else {
                throw AudioBufferListFileWriterError.formatConversionFailed
            }

            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
                guard let next = feed.take() else {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                inputStatus.pointee = .haveData
                return next
            }

            switch status {
            case .haveData:
                if output.frameLength > 0 {
                    try writeBuffer(audioFile, output)
                }
            case .inputRanDry:
                if output.frameLength > 0 {
                    try writeBuffer(audioFile, output)
                }
                return
            case .endOfStream:
                return
            case .error:
                throw conversionError ?? AudioBufferListFileWriterError.formatConversionFailed
            @unknown default:
                throw AudioBufferListFileWriterError.formatConversionFailed
            }
        }
    }

    private func configureChannelMapping(
        _ converter: AVAudioConverter?,
        inputFormat: AVAudioFormat,
        outputFormat: AVAudioFormat
    ) {
        guard channelMapping == .primaryInput,
              inputFormat.channelCount > 0,
              inputFormat.channelCount != outputFormat.channelCount
        else { return }

        converter?.channelMap = Array(repeating: 0, count: Int(outputFormat.channelCount))
        converter?.downmix = false
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

// Hands the single pending buffer to the converter's input block exactly once.
// The block runs synchronously inside convert(), but is typed @Sendable.
private final class ConverterFeed: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}

private final class PendingAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    weak var pool: AudioPCMBufferPool?

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func recycle() {
        pool?.recycle(self)
    }
}
