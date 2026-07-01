import AVFoundation
import Foundation

struct AudioMixerWriter {
    private let outputSampleRate = 48_000.0
    private let outputChannelCount: AVAudioChannelCount = 2
    private let maximumFrameCount: AVAudioFrameCount = 4_096
    private let limiterCeiling: Float = 0.98

    func mix(inputs: [AudioMixerInput], outputURL: URL) async throws -> AudioMixResult {
        let usableInputs = try await usableInputs(from: inputs)
        guard !usableInputs.isEmpty else {
            throw RecordingLibraryError.missingFile
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let renderInputs = usableInputs.map(RenderAudioInput.init)
        let timelineDuration = renderInputs
            .map { $0.input.input.startOffset + $0.outputDuration }
            .max() ?? 0
        try render(
            renderInputs: renderInputs,
            timelineDuration: timelineDuration,
            outputURL: outputURL
        )

        return AudioMixResult(
            duration: try await duration(of: outputURL),
            sources: usableInputs.map(\.input.source)
        )
    }

    private func usableInputs(from inputs: [AudioMixerInput]) async throws -> [UsableAudioInput] {
        var usableInputs: [UsableAudioInput] = []

        for input in inputs where FileManager.default.fileExists(atPath: input.url.path) {
            let asset = AVURLAsset(url: input.url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                continue
            }

            guard tracks.first != nil else { continue }

            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                continue
            }

            guard duration.seconds.isFinite, duration.seconds > 0 else { continue }

            usableInputs.append(UsableAudioInput(input: input, duration: duration.seconds))
        }

        return usableInputs
    }

    private func render(
        renderInputs: [RenderAudioInput],
        timelineDuration: TimeInterval,
        outputURL: URL
    ) throws {
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: outputChannelCount,
            interleaved: false
        ) else {
            throw AudioMixerWriterError.couldNotCreateOutputFormat
        }

        let engine = AVAudioEngine()
        let playerNodes = try renderInputs.map { input in
            let playerNode = AVAudioPlayerNode()
            let varispeedNode = AVAudioUnitVarispeed()
            varispeedNode.rate = input.playbackRate

            let file = try AVAudioFile(forReading: input.input.input.url)
            let startFrame = AVAudioFramePosition(round(input.input.input.startOffset * outputSampleRate))
            let startTime = startFrame > 0
                ? AVAudioTime(sampleTime: startFrame, atRate: outputSampleRate)
                : nil
            engine.attach(playerNode)
            engine.attach(varispeedNode)
            engine.connect(playerNode, to: varispeedNode, format: file.processingFormat)
            engine.connect(varispeedNode, to: engine.mainMixerNode, format: file.processingFormat)
            playerNode.scheduleFile(file, at: startTime)
            return playerNode
        }

        try engine.enableManualRenderingMode(
            .offline,
            format: outputFormat,
            maximumFrameCount: maximumFrameCount
        )

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: outputSampleRate,
                AVNumberOfChannelsKey: Int(outputChannelCount),
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )

        try engine.start()
        playerNodes.forEach { $0.play() }

        let targetFrames = max(
            AVAudioFramePosition(1),
            AVAudioFramePosition(ceil(timelineDuration * outputSampleRate))
        )

        defer {
            playerNodes.forEach { $0.stop() }
            engine.stop()
            engine.disableManualRenderingMode()
        }

        while engine.manualRenderingSampleTime < targetFrames {
            let remainingFrames = targetFrames - engine.manualRenderingSampleTime
            let framesToRender = min(maximumFrameCount, AVAudioFrameCount(remainingFrames))

            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: engine.manualRenderingFormat,
                frameCapacity: framesToRender
            ) else {
                throw AudioMixerWriterError.couldNotCreateRenderBuffer
            }

            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                applyLimiter(to: buffer)
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                continue
            case .error:
                throw AudioMixerWriterError.renderFailed
            @unknown default:
                throw AudioMixerWriterError.renderFailed
            }
        }
    }

    private func applyLimiter(to buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                samples[frame] = min(limiterCeiling, max(-limiterCeiling, samples[frame]))
            }
        }
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }
}

private struct UsableAudioInput {
    var input: AudioMixerInput
    var duration: TimeInterval
}

private struct RenderAudioInput {
    var input: UsableAudioInput
    var outputDuration: TimeInterval
    var playbackRate: Float

    init(input: UsableAudioInput) {
        self.input = input

        let targetDuration = input.input.targetDuration
        let usableTargetDuration = targetDuration.flatMap { duration -> TimeInterval? in
            guard duration.isFinite, duration > 0 else { return nil }
            return duration
        }
        let unclampedRate = input.duration / (usableTargetDuration ?? input.duration)
        let clampedRate = min(4, max(0.25, unclampedRate))

        playbackRate = Float(clampedRate)
        outputDuration = input.duration / clampedRate
    }
}

struct AudioMixerInput: Sendable, Equatable {
    var url: URL
    var source: RecordingSource
    var startOffset: TimeInterval
    var targetDuration: TimeInterval?

    init(
        url: URL,
        source: RecordingSource,
        startOffset: TimeInterval = 0,
        targetDuration: TimeInterval? = nil
    ) {
        self.url = url
        self.source = source
        self.startOffset = max(0, startOffset)
        self.targetDuration = targetDuration.map { max(0, $0) }
    }
}

struct AudioMixResult: Sendable, Equatable {
    var duration: TimeInterval
    var sources: [RecordingSource]
}

enum AudioMixerWriterError: LocalizedError {
    case couldNotCreateOutputFormat
    case couldNotCreateRenderBuffer
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .couldNotCreateOutputFormat:
            "Wiretap could not create the 48 kHz stereo output format."
        case .couldNotCreateRenderBuffer:
            "Wiretap could not allocate an audio render buffer."
        case .renderFailed:
            "Wiretap could not render the mixed audio file."
        }
    }
}
