import AVFoundation
import Foundation

struct AudioMixerWriter {
    private let logger = WiretapLog.mixer
    private let outputSampleRate = 48_000.0
    private let outputChannelCount: AVAudioChannelCount = 2
    private let maximumFrameCount: AVAudioFrameCount = 4_096
    private let limiter = AudioSampleLimiter(ceiling: 0.95)
    private let maximumConsecutiveRenderStalls = 128
    private let microphoneGain: Float

    // Raw physical-device capture does not apply the automatic gain that the
    // former live voice-processing path supplied. Restore roughly +9.5 dB so
    // speech remains intelligible beside full-level system audio.
    init(microphoneGain: Float = 3.0) {
        self.microphoneGain = max(0, microphoneGain)
    }

    func mix(inputs: [AudioMixerInput], outputURL: URL) async throws -> AudioMixResult {
        logger.info("Mix requested inputs=\(inputs.count, privacy: .public) output=\(outputURL.lastPathComponent, privacy: .public)")
        let prepared = try prepareInputs(inputs, beside: outputURL)
        defer {
            prepared.temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let usableInputs = try await usableInputs(from: prepared.inputs)
        guard !usableInputs.isEmpty else {
            logger.error("Mix failed: no usable audio inputs")
            throw RecordingLibraryError.missingFile
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let renderInputs = usableInputs.map(RenderAudioInput.init)
        let timelineDuration = renderInputs
            .map { $0.input.input.startOffset + $0.outputDuration }
            .max() ?? 0
        for input in renderInputs {
            logger.info(
                "Mix input source=\(input.input.input.source.rawValue, privacy: .public) duration=\(input.input.duration, privacy: .public) offset=\(input.input.input.startOffset, privacy: .public) target=\(input.input.input.targetDuration ?? 0, privacy: .public) outputDuration=\(input.outputDuration, privacy: .public)"
            )
        }
        logger.info("Rendering mix timelineDuration=\(timelineDuration, privacy: .public)")
        let renderedDuration = try render(
            renderInputs: renderInputs,
            timelineDuration: timelineDuration,
            outputURL: outputURL
        )
        guard FinalizedAudioFileValidator.isUsable(
            outputURL,
            expectedDuration: renderedDuration
        ) else {
            throw AudioMixerWriterError.unusableOutput
        }

        let sources = usableInputs.map(\.input.source)
        logger.info(
            "Mix completed duration=\(renderedDuration, privacy: .public) sources=\(WiretapLog.sourceSummary(sources), privacy: .public)"
        )
        return AudioMixResult(
            duration: renderedDuration,
            sources: sources
        )
    }

    private func prepareInputs(
        _ inputs: [AudioMixerInput],
        beside outputURL: URL
    ) throws -> (inputs: [AudioMixerInput], temporaryURLs: [URL]) {
        var preparedInputs: [AudioMixerInput] = []
        var temporaryURLs: [URL] = []
        var completed = false
        defer {
            if !completed {
                temporaryURLs.forEach { try? FileManager.default.removeItem(at: $0) }
            }
        }

        for input in inputs {
            switch input.microphonePostProcessing {
            case .none:
                preparedInputs.append(input)
            case .soundIsolation:
                let processedURL = outputURL.deletingLastPathComponent().appendingPathComponent(
                    ".wiretap-mic-processed-\(UUID().uuidString).caf"
                )
                temporaryURLs.append(processedURL)
                do {
                    let result = try OfflineMicrophoneProcessor().applySoundIsolation(
                        inputURL: input.url,
                        outputURL: processedURL
                    )
                    guard OfflineMicrophoneProcessingPolicy.shouldUseProcessed(result) else {
                        throw OfflineMicrophoneProcessorError.unusableOutput
                    }
                    logger.info(
                        "Microphone post-processing=sound-isolation rawPeak=\(result.rawMetrics.peak, privacy: .public) rawRMS=\(result.rawMetrics.rootMeanSquare, privacy: .public) rawNonzero=\(result.rawMetrics.nonzeroSampleCount, privacy: .public)/\(result.rawMetrics.sampleCount, privacy: .public) processedPeak=\(result.processedMetrics.peak, privacy: .public) processedRMS=\(result.processedMetrics.rootMeanSquare, privacy: .public) processedNonzero=\(result.processedMetrics.nonzeroSampleCount, privacy: .public)/\(result.processedMetrics.sampleCount, privacy: .public)"
                    )
                    var processedInput = input
                    processedInput.url = processedURL
                    processedInput.microphonePostProcessing = .none
                    preparedInputs.append(processedInput)
                } catch {
                    // Voice isolation is an enhancement, not a prerequisite.
                    // Keep the raw source so a missing Audio Unit or one bad
                    // microphone file cannot discard otherwise valid audio.
                    logger.error(
                        "Microphone post-processing failed; falling back to raw input error=\(error.localizedDescription, privacy: .public)"
                    )
                    var rawInput = input
                    rawInput.microphonePostProcessing = .none
                    preparedInputs.append(rawInput)
                }
            }
        }

        completed = true
        return (preparedInputs, temporaryURLs)
    }

    private func usableInputs(from inputs: [AudioMixerInput]) async throws -> [UsableAudioInput] {
        var usableInputs: [UsableAudioInput] = []

        for input in inputs where FileManager.default.fileExists(atPath: input.url.path) {
            let asset = AVURLAsset(url: input.url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                logger.error(
                    "Skipping mix input source=\(input.source.rawValue, privacy: .public) reason=trackLoadFailed error=\(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            guard tracks.first != nil else {
                logger.warning("Skipping mix input source=\(input.source.rawValue, privacy: .public) reason=noAudioTrack")
                continue
            }

            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                logger.error(
                    "Skipping mix input source=\(input.source.rawValue, privacy: .public) reason=durationLoadFailed error=\(error.localizedDescription, privacy: .public)"
                )
                continue
            }

            guard duration.seconds.isFinite, duration.seconds > 0 else {
                logger.warning(
                    "Skipping mix input source=\(input.source.rawValue, privacy: .public) reason=invalidDuration duration=\(duration.seconds, privacy: .public)"
                )
                continue
            }

            usableInputs.append(UsableAudioInput(input: input, duration: duration.seconds))
        }

        return usableInputs
    }

    private func render(
        renderInputs: [RenderAudioInput],
        timelineDuration: TimeInterval,
        outputURL: URL
    ) throws -> TimeInterval {
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

            let file = try AVAudioFile(forReading: input.input.input.url)
            playerNode.volume = sourceGain(for: input.input.input.source)
            let startFrame = AVAudioFramePosition(round(input.input.input.startOffset * outputSampleRate))
            let startTime = startFrame > 0
                ? AVAudioTime(sampleTime: startFrame, atRate: outputSampleRate)
                : nil
            engine.attach(playerNode)
            engine.connect(playerNode, to: engine.mainMixerNode, format: file.processingFormat)
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

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw AudioMixerWriterError.couldNotCreateRenderBuffer
        }

        var consecutiveRenderStalls = 0

        defer {
            playerNodes.forEach { $0.stop() }
            engine.stop()
            engine.disableManualRenderingMode()
        }

        while engine.manualRenderingSampleTime < targetFrames {
            let remainingFrames = targetFrames - engine.manualRenderingSampleTime
            let framesToRender = min(maximumFrameCount, AVAudioFrameCount(remainingFrames))
            let sampleTimeBeforeRender = engine.manualRenderingSampleTime

            let status = try engine.renderOffline(framesToRender, to: buffer)
            switch status {
            case .success:
                consecutiveRenderStalls = 0
                limiter.apply(to: buffer)
                if buffer.frameLength > 0 {
                    try outputFile.write(from: buffer)
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                if engine.manualRenderingSampleTime <= sampleTimeBeforeRender {
                    consecutiveRenderStalls += 1
                } else {
                    consecutiveRenderStalls = 0
                }

                if consecutiveRenderStalls >= maximumConsecutiveRenderStalls {
                    throw AudioMixerWriterError.renderStalled
                }

                continue
            case .error:
                throw AudioMixerWriterError.renderFailed
            @unknown default:
                throw AudioMixerWriterError.renderFailed
            }
        }

        return TimeInterval(targetFrames) / outputSampleRate
    }

    private func sourceGain(for source: RecordingSource) -> Float {
        switch source {
        case .microphone:
            microphoneGain
        case .systemAudio:
            1
        }
    }
}

struct AudioSampleLimiter: Sendable {
    var ceiling: Float

    func apply(to buffer: AVAudioPCMBuffer) {
        guard ceiling > 0,
              let channelData = buffer.floatChannelData
        else { return }

        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        guard channelCount > 0, frameLength > 0 else { return }

        var peak: Float = 0
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                peak = max(peak, abs(samples[frame]))
            }
        }

        guard peak > ceiling else { return }

        let gain = ceiling / peak
        for channel in 0..<channelCount {
            let samples = channelData[channel]
            for frame in 0..<frameLength {
                samples[frame] *= gain
            }
        }
    }
}

private struct UsableAudioInput {
    var input: AudioMixerInput
    var duration: TimeInterval
}

private struct RenderAudioInput {
    var input: UsableAudioInput
    var outputDuration: TimeInterval

    init(input: UsableAudioInput) {
        self.input = input

        let targetDuration = input.input.targetDuration
        let usableTargetDuration = targetDuration.flatMap { duration -> TimeInterval? in
            guard duration.isFinite, duration > 0 else { return nil }
            return duration
        }

        outputDuration = max(input.duration, usableTargetDuration ?? input.duration)
    }
}

struct AudioMixerInput: Sendable, Equatable {
    var url: URL
    var source: RecordingSource
    var startOffset: TimeInterval
    var targetDuration: TimeInterval?
    var microphonePostProcessing: MicrophonePostProcessing

    init(
        url: URL,
        source: RecordingSource,
        startOffset: TimeInterval = 0,
        targetDuration: TimeInterval? = nil,
        microphonePostProcessing: MicrophonePostProcessing = .none
    ) {
        self.url = url
        self.source = source
        self.startOffset = max(0, startOffset)
        self.targetDuration = targetDuration.map { max(0, $0) }
        self.microphonePostProcessing = microphonePostProcessing
    }
}

struct AudioMixResult: Sendable, Equatable {
    var duration: TimeInterval
    var sources: [RecordingSource]
}

enum AudioMixerWriterError: LocalizedError {
    case couldNotCreateOutputFormat
    case couldNotCreateRenderBuffer
    case renderStalled
    case renderFailed
    case unusableOutput

    var errorDescription: String? {
        switch self {
        case .couldNotCreateOutputFormat:
            "Wiretap could not create the 48 kHz stereo output format."
        case .couldNotCreateRenderBuffer:
            "Wiretap could not allocate an audio render buffer."
        case .renderStalled:
            "Wiretap could not make progress while rendering the mixed audio file."
        case .renderFailed:
            "Wiretap could not render the mixed audio file."
        case .unusableOutput:
            "Wiretap could not verify the completed mixed audio file."
        }
    }
}
