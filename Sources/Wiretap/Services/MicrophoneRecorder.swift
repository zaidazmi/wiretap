import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

protocol MicrophoneRecording: AnyObject {
    var isRecording: Bool { get }
    var capturedFrameCount: Int64 { get }

    func startRecording(to url: URL) throws
    @discardableResult func stopRecording() -> CaptureStopResult
}

final class MicrophoneRecorder: MicrophoneRecording {
    private let system = AudioHardwareSystem.shared
    private let ioQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.microphone-recorder", qos: .userInitiated)
    private var device: AudioHardwareDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var processingEngine: AVAudioEngine?
    private var processingSink: AVAudioSinkNode?
    private var voiceIsolationEffect: AVAudioUnitEffect?
    private var writer: AudioBufferListFileWriter?
    private var startedAt: Date?
    private lazy var formatObserver = AudioDeviceFormatObserver(queue: ioQueue)
    private let logger = WiretapLog.capture

    var isRecording: Bool {
        ioProcID != nil || processingEngine?.isRunning == true
    }

    var capturedFrameCount: Int64 {
        writer?.capturedFrameCount ?? 0
    }

    func startRecording(to url: URL) throws {
        stopRecording()

        do {
            guard let device = try system.defaultInputDevice else {
                throw AudioRecordingError.noDefaultInputDevice
            }

            let outputRoute = try? currentOutputRoute()
            switch MicrophoneCapturePolicy.mode(for: outputRoute) {
            case .speakerProcessed:
                do {
                    try startVoiceIsolatedRecording(
                        to: url,
                        inputDevice: device,
                        outputRoute: outputRoute
                    )
                } catch {
                    // Sound Isolation does not take ownership of the output
                    // device, so it avoids VoiceProcessingIO's unavoidable
                    // speaker ducking. Fall back to acoustic echo cancellation
                    // only if the effect is unavailable on this Mac.
                    logger.warning(
                        "Voice-isolated microphone capture unavailable; falling back to VoiceProcessingIO error=\(error.localizedDescription, privacy: .public)"
                    )
                    stopRecording()
                    try startEchoCancelledRecording(
                        to: url,
                        inputDevice: device,
                        outputRoute: outputRoute
                    )
                }
            case .raw:
                try startRawRecording(to: url, device: device, outputRoute: outputRoute)
            }
        } catch {
            logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            stopRecording()
            throw error
        }
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        let wasRecording = device != nil || processingEngine != nil || writer != nil

        formatObserver.stop()

        if let processingEngine {
            processingEngine.stop()
        }

        if let device, let ioProcID {
            AudioDeviceStop(device.id, ioProcID)
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let flushResult = writer?.flush()
        let result = CaptureStopResult(
            duration: duration,
            capturedFrameCount: flushResult?.capturedFrameCount ?? 0,
            droppedFrameCount: flushResult?.droppedFrameCount ?? 0,
            writeError: flushResult?.writeError
        )
        device = nil
        ioProcID = nil
        processingEngine = nil
        processingSink = nil
        voiceIsolationEffect = nil
        writer = nil
        startedAt = nil

        if wasRecording {
            logger.info(
                "Microphone capture stopped duration=\(result.duration, privacy: .public) capturedFrames=\(result.capturedFrameCount, privacy: .public) droppedFrames=\(result.droppedFrameCount, privacy: .public) writeError=\(result.writeError?.localizedDescription ?? "none", privacy: .public)"
            )
        }

        return result
    }

    private func startVoiceIsolatedRecording(
        to url: URL,
        inputDevice: AudioHardwareDevice,
        outputRoute: MicrophoneOutputRoute?
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareInputFormat.channelCount > 0, hardwareInputFormat.sampleRate > 0 else {
            throw AudioRecordingError.noDefaultInputDevice
        }
        guard let captureFormat = MicrophoneProcessingFormat.captureFormat(
            sampleRate: hardwareInputFormat.sampleRate,
            hardwareChannelCount: hardwareInputFormat.channelCount
        ) else {
            throw AudioRecordingError.unsupportedFormat
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
        let writer = try AudioBufferListFileWriter(outputURL: url, inputFormat: captureFormat)
        let sinkNode = AVAudioSinkNode { [weak writer] timestamp, _, inputData in
            let sampleTime = timestamp.pointee.mFlags.contains(.sampleTimeValid)
                ? timestamp.pointee.mSampleTime
                : nil
            writer?.write(inputData: inputData, sampleTime: sampleTime)
            return noErr
        }

        engine.attach(effect)
        engine.attach(sinkNode)
        engine.connect(inputNode, to: effect, format: captureFormat)
        engine.connect(effect, to: sinkNode, format: captureFormat)

        self.writer = writer
        processingEngine = engine
        processingSink = sinkNode
        voiceIsolationEffect = effect

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioRecordingError.echoCancellationUnavailable(underlying: error)
        }

        startedAt = Date()
        logger.info(
            "Microphone capture started mode=voice-isolated inputDevice=\(inputDevice.id, privacy: .public) outputRoute=\(outputRoute?.name ?? "unknown", privacy: .private(mask: .hash)) hardwareFormat=\(WiretapLog.audioFormatSummary(hardwareInputFormat), privacy: .public) captureFormat=\(WiretapLog.audioFormatSummary(captureFormat), privacy: .public)"
        )
    }

    private func startEchoCancelledRecording(
        to url: URL,
        inputDevice: AudioHardwareDevice,
        outputRoute: MicrophoneOutputRoute?
    ) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        do {
            try inputNode.setVoiceProcessingEnabled(true)
        } catch {
            throw AudioRecordingError.echoCancellationUnavailable(underlying: error)
        }

        // Advanced ducking limits attenuation to periods where local speech is
        // actually present. The minimum level avoids the always-on system-audio
        // attenuation caused by the old voice-processing implementation.
        inputNode.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: true,
                duckingLevel: .min
            )
        // Do not inherit a stale muted state from the VoiceProcessingIO unit.
        // A muted VPIO input still renders correctly timed, all-zero buffers,
        // which otherwise looks like a successful microphone recording.
        inputNode.isVoiceProcessingInputMuted = false
        inputNode.isVoiceProcessingBypassed = false
        inputNode.isVoiceProcessingAGCEnabled = false

        let hardwareInputFormat = inputNode.inputFormat(forBus: 0)
        guard hardwareInputFormat.channelCount > 0, hardwareInputFormat.sampleRate > 0 else {
            throw AudioRecordingError.noDefaultInputDevice
        }
        guard let captureFormat = MicrophoneProcessingFormat.captureFormat(
            sampleRate: hardwareInputFormat.sampleRate,
            hardwareChannelCount: hardwareInputFormat.channelCount
        ) else {
            throw AudioRecordingError.unsupportedFormat
        }

        let writer = try AudioBufferListFileWriter(outputURL: url, inputFormat: captureFormat)
        let sinkNode = AVAudioSinkNode { [weak writer] timestamp, _, inputData in
            let sampleTime = timestamp.pointee.mFlags.contains(.sampleTimeValid)
                ? timestamp.pointee.mSampleTime
                : nil
            writer?.write(inputData: inputData, sampleTime: sampleTime)
            return noErr
        }

        // AVAudioSinkNode is the engine's terminal receiver for an input chain.
        // Unlike routing the microphone through a muted output mixer, it pulls
        // the processed VoiceProcessingIO uplink without monitoring the mic to
        // the speakers. Apple explicitly supports the voice-processing unit's
        // client format conversion on this connection.
        engine.attach(sinkNode)
        engine.connect(inputNode, to: sinkNode, format: captureFormat)

        self.writer = writer
        processingEngine = engine
        processingSink = sinkNode

        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioRecordingError.echoCancellationUnavailable(underlying: error)
        }

        startedAt = Date()
        logger.info(
            "Microphone capture started mode=echo-cancelled inputDevice=\(inputDevice.id, privacy: .public) outputRoute=\(outputRoute?.name ?? "unknown", privacy: .private(mask: .hash)) hardwareFormat=\(WiretapLog.audioFormatSummary(hardwareInputFormat), privacy: .public) captureFormat=\(WiretapLog.audioFormatSummary(captureFormat), privacy: .public)"
        )
    }

    private func startRawRecording(
        to url: URL,
        device: AudioHardwareDevice,
        outputRoute: MicrophoneOutputRoute?
    ) throws {
        let inputFormat = try inputFormat(for: device)
        let deviceUID = (try? device.uid) ?? "unknown"
        logger.info(
            "Preparing microphone capture mode=raw device=\(device.id, privacy: .public) uid=\(deviceUID, privacy: .private(mask: .hash)) outputRoute=\(outputRoute?.name ?? "unknown", privacy: .private(mask: .hash)) format=\(WiretapLog.audioFormatSummary(inputFormat), privacy: .public) output=\(url.lastPathComponent, privacy: .public)"
        )
        let writer = try AudioBufferListFileWriter(outputURL: url, inputFormat: inputFormat)
        self.device = device
        self.writer = writer

        var ioProcID: AudioDeviceIOProcID?
        let createStatus = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            device.id,
            ioQueue
        ) { [weak writer] _, inputData, inputTime, _, _ in
            let sampleTime = inputTime.pointee.mFlags.contains(.sampleTimeValid)
                ? inputTime.pointee.mSampleTime
                : nil
            writer?.write(inputData: inputData, sampleTime: sampleTime)
        }

        guard createStatus == noErr, let ioProcID else {
            throw CoreAudioStatusError(status: createStatus, operation: "create microphone IOProc")
        }

        let startStatus = AudioDeviceStart(device.id, ioProcID)
        guard startStatus == noErr else {
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
            throw CoreAudioStatusError(status: startStatus, operation: "start microphone IOProc")
        }

        self.ioProcID = ioProcID
        startedAt = Date()
        formatObserver.start(observing: device.id) { [weak self] in
            self?.refreshCaptureFormat()
        }
        logger.info("Microphone capture started mode=raw device=\(device.id, privacy: .public)")
    }

    private func currentOutputRoute() throws -> MicrophoneOutputRoute? {
        guard let device = try system.defaultOutputDevice else { return nil }

        let terminalTypes = try device.streams.compactMap { stream -> UInt32? in
            guard try stream.direction == .output else { return nil }
            return try stream.terminalType
        }

        return try MicrophoneOutputRoute(
            name: device.name,
            transportType: device.transportType,
            terminalTypes: terminalTypes
        )
    }

    private func refreshCaptureFormat() {
        guard let device, let writer else { return }
        guard let format = try? inputFormat(for: device) else { return }

        writer.updateInputFormat(format)
    }

    private func inputFormat(for device: AudioHardwareDevice) throws -> AVAudioFormat {
        let streams = try device.streams

        for stream in streams where (try? stream.direction) == .input {
            var streamDescription = try stream.virtualFormat
            if let format = AVAudioFormat(streamDescription: &streamDescription),
               format.channelCount > 0 {
                return format
            }
        }

        throw AudioRecordingError.unsupportedFormat
    }
}

enum MicrophoneCaptureMode: Equatable {
    case speakerProcessed
    case raw
}

enum MicrophoneProcessingFormat {
    static func captureFormat(
        sampleRate: Double,
        hardwareChannelCount: AVAudioChannelCount
    ) -> AVAudioFormat? {
        guard sampleRate > 0, hardwareChannelCount > 0 else {
            return nil
        }

        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        )
    }
}

struct MicrophoneOutputRoute: Equatable {
    var name: String
    var transportType: UInt32
    var terminalTypes: [UInt32] = []
}

enum MicrophoneCapturePolicy {
    static func mode(for outputRoute: MicrophoneOutputRoute?) -> MicrophoneCaptureMode {
        guard let outputRoute else {
            // Unknown and speaker-like routes need isolation from speaker audio.
            // Raw capture is only safe when isolation is positively identified.
            return .speakerProcessed
        }

        if outputRoute.transportType == kAudioDeviceTransportTypeBluetooth ||
            outputRoute.transportType == kAudioDeviceTransportTypeBluetoothLE {
            return .raw
        }

        if outputRoute.terminalTypes.contains(kAudioStreamTerminalTypeHeadphones) {
            return .raw
        }

        let normalizedName = outputRoute.name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        let isolatedOutputNameFragments = [
            "airpods",
            "earbud",
            "earphone",
            "headphone",
            "headset",
            "in-ear"
        ]

        return isolatedOutputNameFragments.contains(where: normalizedName.contains)
            ? .raw
            : .speakerProcessed
    }
}

enum AudioRecordingError: LocalizedError {
    case noDefaultInputDevice
    case unsupportedFormat
    case echoCancellationUnavailable(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noDefaultInputDevice:
            "Wiretap could not find a default microphone input device."
        case .unsupportedFormat:
            "Wiretap could not start recording from the default microphone."
        case .echoCancellationUnavailable:
            "Wiretap could not enable speaker echo cancellation for the current audio route. Choose headphones or try reconnecting the input and output devices."
        }
    }
}
