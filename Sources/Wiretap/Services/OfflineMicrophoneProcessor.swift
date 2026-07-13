import AVFoundation
import AudioToolbox
import Foundation

/// Processes the microphone after capture so competing VoiceChat clients cannot
/// reconfigure or stop Wiretap's live input graph. The first physical microphone
/// channel is selected explicitly; AVAudioEngine's implicit multichannel downmix
/// can phase-cancel a Mac microphone array when WhatsApp exposes all channels.
struct OfflineMicrophoneProcessor {
    private let maximumFrameCount: AVAudioFrameCount = 4_096
    private let maximumConsecutiveRenderStalls = 128

    func applySoundIsolation(inputURL: URL, outputURL: URL) throws -> OfflineMicrophoneProcessingResult {
        let directory = outputURL.deletingLastPathComponent()
        let token = UUID().uuidString
        let monoURL = directory.appendingPathComponent(".wiretap-mic-mono-\(token).caf")
        let paddedURL = directory.appendingPathComponent(".wiretap-mic-isolated-\(token).caf")
        defer {
            try? FileManager.default.removeItem(at: monoURL)
            try? FileManager.default.removeItem(at: paddedURL)
        }

        let rawMetrics = try extractPrimaryChannel(inputURL: inputURL, outputURL: monoURL)
        let isolatedMetrics = try renderSoundIsolation(
            inputURL: monoURL,
            paddedURL: paddedURL,
            outputURL: outputURL
        )
        return OfflineMicrophoneProcessingResult(
            rawMetrics: rawMetrics,
            processedMetrics: isolatedMetrics
        )
    }

    /// Copies channel zero instead of averaging the input channels. Core Audio's
    /// channel map contract guarantees that `[0]` derives the mono output only
    /// from the first input channel.
    func extractPrimaryChannel(inputURL: URL, outputURL: URL) throws -> AudioSignalMetrics {
        let inputFile = try AVAudioFile(
            forReading: inputURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let inputFormat = inputFile.processingFormat
        guard inputFormat.channelCount > 0,
              let monoFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: inputFormat.sampleRate,
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: monoFormat)
        else {
            throw OfflineMicrophoneProcessorError.unsupportedInputFormat
        }

        converter.channelMap = [0]
        converter.downmix = false

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: monoFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var accumulator = AudioSignalAccumulator()

        while inputFile.framePosition < inputFile.length {
            let remaining = inputFile.length - inputFile.framePosition
            let capacity = AVAudioFrameCount(min(Int64(maximumFrameCount), remaining))
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: capacity
            ), let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: monoFormat,
                frameCapacity: capacity
            ) else {
                throw OfflineMicrophoneProcessorError.couldNotCreateBuffer
            }

            try inputFile.read(into: inputBuffer, frameCount: capacity)
            guard inputBuffer.frameLength > 0 else { break }
            try converter.convert(to: outputBuffer, from: inputBuffer)
            accumulator.add(outputBuffer)
            try outputFile.write(from: outputBuffer)
        }

        return accumulator.metrics
    }

    private func renderSoundIsolation(
        inputURL: URL,
        paddedURL: URL,
        outputURL: URL
    ) throws -> AudioSignalMetrics {
        let inputFile = try AVAudioFile(
            forReading: inputURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = inputFile.processingFormat
        guard format.channelCount == 1 else {
            throw OfflineMicrophoneProcessorError.unsupportedInputFormat
        }

        let component = AudioComponentDescription(
            componentType: kAudioUnitType_Effect,
            componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        let effect = AVAudioUnitEffect(audioComponentDescription: component)
        effect.auAudioUnit.parameterTree?
            .parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?
            .value = 100

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.attach(effect)
        engine.connect(player, to: effect, format: format)
        engine.connect(effect, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(
            .offline,
            format: format,
            maximumFrameCount: maximumFrameCount
        )
        engine.prepare()

        let latencyFrames = AVAudioFramePosition(
            ceil(effect.auAudioUnit.latency * format.sampleRate)
        )
        let targetFrames = max(AVAudioFramePosition(1), inputFile.length + latencyFrames)
        let paddedFile = try AVAudioFile(
            forWriting: paddedURL,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        guard let renderBuffer = AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat,
            frameCapacity: maximumFrameCount
        ) else {
            throw OfflineMicrophoneProcessorError.couldNotCreateBuffer
        }

        player.scheduleFile(inputFile, at: nil)
        try engine.start()
        player.play()
        var consecutiveRenderStalls = 0

        defer {
            player.stop()
            engine.stop()
            engine.disableManualRenderingMode()
        }

        while engine.manualRenderingSampleTime < targetFrames {
            let remaining = targetFrames - engine.manualRenderingSampleTime
            let frameCount = min(maximumFrameCount, AVAudioFrameCount(remaining))
            let sampleTimeBeforeRender = engine.manualRenderingSampleTime
            let status = try engine.renderOffline(frameCount, to: renderBuffer)

            switch status {
            case .success:
                consecutiveRenderStalls = 0
                if renderBuffer.frameLength > 0 {
                    try paddedFile.write(from: renderBuffer)
                }
            case .insufficientDataFromInputNode, .cannotDoInCurrentContext:
                consecutiveRenderStalls = engine.manualRenderingSampleTime <= sampleTimeBeforeRender
                    ? consecutiveRenderStalls + 1
                    : 0
                if consecutiveRenderStalls >= maximumConsecutiveRenderStalls {
                    throw OfflineMicrophoneProcessorError.renderStalled
                }
            case .error:
                throw OfflineMicrophoneProcessorError.renderFailed
            @unknown default:
                throw OfflineMicrophoneProcessorError.renderFailed
            }
        }

        return try trimLatency(
            paddedURL: paddedURL,
            outputURL: outputURL,
            latencyFrames: latencyFrames,
            outputFrameCount: inputFile.length
        )
    }

    private func trimLatency(
        paddedURL: URL,
        outputURL: URL,
        latencyFrames: AVAudioFramePosition,
        outputFrameCount: AVAudioFramePosition
    ) throws -> AudioSignalMetrics {
        let inputFile = try AVAudioFile(
            forReading: paddedURL,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        inputFile.framePosition = min(latencyFrames, inputFile.length)
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: inputFile.processingFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        var remaining = min(outputFrameCount, inputFile.length - inputFile.framePosition)
        var accumulator = AudioSignalAccumulator()

        while remaining > 0 {
            let frameCount = AVAudioFrameCount(min(Int64(maximumFrameCount), remaining))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFile.processingFormat,
                frameCapacity: frameCount
            ) else {
                throw OfflineMicrophoneProcessorError.couldNotCreateBuffer
            }
            try inputFile.read(into: buffer, frameCount: frameCount)
            guard buffer.frameLength > 0 else { break }
            accumulator.add(buffer)
            try outputFile.write(from: buffer)
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }

        return accumulator.metrics
    }
}

struct OfflineMicrophoneProcessingResult: Equatable {
    var rawMetrics: AudioSignalMetrics
    var processedMetrics: AudioSignalMetrics
}

struct AudioSignalMetrics: Equatable {
    var peak: Float = 0
    var rootMeanSquare: Float = 0
    var nonzeroSampleCount: Int64 = 0
    var sampleCount: Int64 = 0
}

private struct AudioSignalAccumulator {
    private(set) var peak: Float = 0
    private(set) var squaredTotal: Double = 0
    private(set) var nonzeroSampleCount: Int64 = 0
    private(set) var sampleCount: Int64 = 0

    mutating func add(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        for channel in 0..<Int(buffer.format.channelCount) {
            let samples = channelData[channel]
            for frame in 0..<Int(buffer.frameLength) {
                let sample = samples[frame]
                peak = max(peak, abs(sample))
                squaredTotal += Double(sample * sample)
                if sample != 0 {
                    nonzeroSampleCount += 1
                }
                sampleCount += 1
            }
        }
    }

    var metrics: AudioSignalMetrics {
        AudioSignalMetrics(
            peak: peak,
            rootMeanSquare: sampleCount > 0
                ? Float(sqrt(squaredTotal / Double(sampleCount)))
                : 0,
            nonzeroSampleCount: nonzeroSampleCount,
            sampleCount: sampleCount
        )
    }
}

enum OfflineMicrophoneProcessorError: LocalizedError {
    case unsupportedInputFormat
    case couldNotCreateBuffer
    case renderStalled
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedInputFormat:
            "Wiretap could not read the captured microphone format."
        case .couldNotCreateBuffer:
            "Wiretap could not allocate a microphone processing buffer."
        case .renderStalled:
            "Wiretap's microphone processing stopped making progress."
        case .renderFailed:
            "Wiretap could not apply microphone voice isolation."
        }
    }
}
