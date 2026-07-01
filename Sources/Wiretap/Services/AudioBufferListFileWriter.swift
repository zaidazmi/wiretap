import AVFoundation

final class AudioBufferListFileWriter {
    private let inputFormat: AVAudioFormat
    private let audioFile: AVAudioFile

    init(outputURL: URL, inputFormat: AVAudioFormat) throws {
        let channelCount = max(1, Int(inputFormat.channelCount))
        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: inputFormat.sampleRate,
            AVNumberOfChannelsKey: channelCount,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        self.inputFormat = inputFormat
        self.audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )
    }

    func write(inputData: UnsafePointer<AudioBufferList>) {
        guard let firstBuffer = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: inputData)
        ).first else { return }

        let streamDescription = inputFormat.streamDescription.pointee
        let bytesPerFrame = max(1, Int(streamDescription.mBytesPerFrame))
        let frameLength = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameLength > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: UnsafeMutablePointer(mutating: inputData),
                deallocator: nil
              )
        else { return }

        buffer.frameLength = frameLength
        try? audioFile.write(from: buffer)
    }
}
