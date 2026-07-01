import AVFoundation
import Foundation

final class AudioBufferListFileWriter {
    private let inputFormat: AVAudioFormat
    private let state: WriteState
    private let writeQueue: DispatchQueue
    private let writeQueueKey = DispatchSpecificKey<Bool>()

    init(outputURL: URL, inputFormat: AVAudioFormat) throws {
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
        ))
        self.writeQueue = DispatchQueue(
            label: "dev.zaidazmi.Wiretap.audio-file-writer.\(UUID().uuidString)",
            qos: .utility
        )
        self.writeQueue.setSpecific(key: writeQueueKey, value: true)
    }

    deinit {
        flush()
    }

    func write(inputData: UnsafePointer<AudioBufferList>) {
        guard let buffer = copiedBuffer(from: inputData) else { return }
        let pendingBuffer = PendingAudioBuffer(buffer: buffer)
        writeQueue.async { [state, pendingBuffer] in
            try? state.audioFile.write(from: pendingBuffer.buffer)
        }
    }

    func flush() {
        guard DispatchQueue.getSpecific(key: writeQueueKey) != true else { return }
        writeQueue.sync {}
    }

    private func copiedBuffer(from inputData: UnsafePointer<AudioBufferList>) -> AVAudioPCMBuffer? {
        guard let firstBuffer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        ).first else { return nil }

        let streamDescription = inputFormat.streamDescription.pointee
        guard streamDescription.mBytesPerFrame > 0 else { return nil }

        let bytesPerFrame = Int(streamDescription.mBytesPerFrame)
        let frameLength = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameLength > 0 else { return nil }

        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: inputFormat,
            frameCapacity: frameLength
        )
        else { return nil }

        copiedBuffer.frameLength = frameLength
        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(
            copiedBuffer.mutableAudioBufferList
        )

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

        return copiedBuffer
    }
}

private final class WriteState: @unchecked Sendable {
    let audioFile: AVAudioFile

    init(audioFile: AVAudioFile) {
        self.audioFile = audioFile
    }
}

private final class PendingAudioBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
