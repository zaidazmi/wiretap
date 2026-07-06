import AVFoundation
import Foundation

protocol MicrophoneRecording: AnyObject {
    var isRecording: Bool { get }
    var capturedFrameCount: Int64 { get }

    func startRecording(to url: URL) throws
    @discardableResult func stopRecording() -> CaptureStopResult
}

final class MicrophoneRecorder: MicrophoneRecording {
    private var engine: AVAudioEngine?
    private var writer: AudioBufferListFileWriter?
    private var startedAt: Date?
    private let logger = WiretapLog.capture

    var isRecording: Bool {
        engine?.isRunning == true
    }

    var capturedFrameCount: Int64 {
        writer?.capturedFrameCount ?? 0
    }

    func startRecording(to url: URL) throws {
        stopRecording()

        do {
            let engine = AVAudioEngine()
            let inputNode = engine.inputNode

            do {
                try inputNode.setVoiceProcessingEnabled(true)
                inputNode.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                        enableAdvancedDucking: false,
                        duckingLevel: .min
                    )
            } catch {
                logger.warning(
                    "Microphone voice processing unavailable; continuing with raw input error=\(error.localizedDescription, privacy: .public)"
                )
            }

            let inputFormat = inputNode.outputFormat(forBus: 0)
            guard inputFormat.channelCount > 0,
                  inputFormat.sampleRate > 0
            else {
                throw AudioRecordingError.noDefaultInputDevice
            }

            logger.info(
                "Preparing microphone capture format=\(WiretapLog.audioFormatSummary(inputFormat), privacy: .public) voiceProcessing=\(inputNode.isVoiceProcessingEnabled, privacy: .public) output=\(url.lastPathComponent, privacy: .public)"
            )
            let writer = try AudioBufferListFileWriter(outputURL: url, inputFormat: inputFormat)

            inputNode.installTap(
                onBus: 0,
                bufferSize: 1_024,
                format: inputFormat
            ) { [weak self] buffer, _ in
                self?.writer?.write(inputData: buffer.audioBufferList)
            }

            engine.prepare()

            do {
                try engine.start()
            } catch {
                inputNode.removeTap(onBus: 0)
                throw error
            }

            self.engine = engine
            self.writer = writer
            self.startedAt = Date()
            logger.info("Microphone capture started voiceProcessing=\(inputNode.isVoiceProcessingEnabled, privacy: .public)")
        } catch {
            logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            stopRecording()
            throw error
        }
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        let wasRecording = engine != nil || writer != nil

        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let flushResult = writer?.flush()
        let result = CaptureStopResult(
            duration: duration,
            capturedFrameCount: flushResult?.capturedFrameCount ?? 0,
            droppedFrameCount: flushResult?.droppedFrameCount ?? 0,
            writeError: flushResult?.writeError
        )
        engine = nil
        writer = nil
        startedAt = nil

        if wasRecording {
            logger.info(
                "Microphone capture stopped duration=\(result.duration, privacy: .public) capturedFrames=\(result.capturedFrameCount, privacy: .public) droppedFrames=\(result.droppedFrameCount, privacy: .public) writeError=\(result.writeError?.localizedDescription ?? "none", privacy: .public)"
            )
        }

        return result
    }
}

enum AudioRecordingError: LocalizedError {
    case noDefaultInputDevice

    var errorDescription: String? {
        switch self {
        case .noDefaultInputDevice:
            "Wiretap could not find a default microphone input device."
        }
    }
}
