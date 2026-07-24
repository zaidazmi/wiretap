import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

protocol MicrophoneRecording: AnyObject {
    var isRecording: Bool { get }
    var capturedFrameCount: Int64 { get }

    func startRecording(to url: URL) throws
    func handleDeviceChange(_ change: AudioDeviceChange) throws
    @discardableResult func stopRecording() -> CaptureStopResult
}

extension MicrophoneRecording {
    func handleDeviceChange(_: AudioDeviceChange) throws {}
}

final class MicrophoneRecorder: MicrophoneRecording {
    private let system = AudioHardwareSystem.shared
    private let ioQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.microphone-recorder", qos: .userInitiated)
    private let ioQueueKey = DispatchSpecificKey<Bool>()
    private var device: AudioHardwareDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioBufferListFileWriter?
    private var postProcessing: MicrophonePostProcessing = .none
    private var startedAt: Date?
    private lazy var formatObserver = AudioDeviceFormatObserver(queue: ioQueue)
    private let logger = WiretapLog.capture

    init() {
        ioQueue.setSpecific(key: ioQueueKey, value: true)
    }

    var isRecording: Bool {
        ioProcID != nil
    }

    var capturedFrameCount: Int64 {
        writer?.capturedFrameCount ?? 0
    }

    func handleDeviceChange(_ change: AudioDeviceChange) throws {
        guard writer != nil else { return }

        switch change {
        case .defaultOutput:
            updatePostProcessingForCurrentOutput()
        case .defaultInput:
            try switchToDefaultInputDevice()
            updatePostProcessingForCurrentOutput()
        }
    }

    func startRecording(to url: URL) throws {
        stopRecording()

        do {
            guard let device = try system.defaultInputDevice else {
                throw AudioRecordingError.noDefaultInputDevice
            }

            let outputRoute = try? currentOutputRoute()
            let processing = MicrophoneCapturePolicy.postProcessing(for: outputRoute)
            try startRawRecording(
                to: url,
                device: device,
                outputRoute: outputRoute,
                postProcessing: processing
            )
        } catch {
            logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            stopRecording()
            throw error
        }
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        let wasRecording = device != nil || writer != nil

        formatObserver.stop()

        if let device, let ioProcID {
            AudioDeviceStop(device.id, ioProcID)
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
        }
        drainIOCallbacks()

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        let flushResult = writer?.flush()
        let result = CaptureStopResult(
            duration: duration,
            capturedFrameCount: flushResult?.capturedFrameCount ?? 0,
            droppedFrameCount: flushResult?.droppedFrameCount ?? 0,
            writeError: flushResult?.writeError,
            microphonePostProcessing: postProcessing
        )
        device = nil
        ioProcID = nil
        writer = nil
        postProcessing = .none
        startedAt = nil

        if wasRecording {
            logger.info(
                "Microphone capture stopped duration=\(result.duration, privacy: .public) capturedFrames=\(result.capturedFrameCount, privacy: .public) droppedFrames=\(result.droppedFrameCount, privacy: .public) postProcessing=\(result.microphonePostProcessing.rawValue, privacy: .public) writeError=\(result.writeError?.localizedDescription ?? "none", privacy: .public)"
            )
        }

        return result
    }

    private func startRawRecording(
        to url: URL,
        device: AudioHardwareDevice,
        outputRoute: MicrophoneOutputRoute?,
        postProcessing: MicrophonePostProcessing
    ) throws {
        let inputFormat = try Self.inputFormat(for: device)
        let deviceUID = (try? device.uid) ?? "unknown"
        logger.info(
            "Preparing microphone capture mode=physical-device device=\(device.id, privacy: .public) uid=\(deviceUID, privacy: .private(mask: .hash)) outputRoute=\(outputRoute?.name ?? "unknown", privacy: .private(mask: .hash)) format=\(WiretapLog.audioFormatSummary(inputFormat), privacy: .public) postProcessing=\(postProcessing.rawValue, privacy: .public) output=\(url.lastPathComponent, privacy: .public)"
        )
        let writer = try AudioBufferListFileWriter(
            outputURL: url,
            inputFormat: inputFormat,
            channelMapping: .primaryInput
        )
        self.device = device
        self.writer = writer
        self.postProcessing = postProcessing

        let ioProcID = try createIOProc(on: device, writer: writer)
        try startIOProc(ioProcID, on: device)

        self.ioProcID = ioProcID
        startedAt = Date()
        observeFormatChanges(on: device, writer: writer)
        logger.info("Microphone capture started mode=physical-device device=\(device.id, privacy: .public) postProcessing=\(postProcessing.rawValue, privacy: .public)")
    }

    private func switchToDefaultInputDevice() throws {
        guard let writer, let previousDevice = device else {
            throw AudioRecordingError.noDefaultInputDevice
        }
        guard let newDevice = try system.defaultInputDevice else {
            // Core Audio can publish a brief "no default" state while a
            // Bluetooth route renegotiates. Keep the current IOProc alive and
            // wait for the settled notification instead of ending the session.
            logger.warning(
                "Default microphone temporarily unavailable; continuing on device=\(previousDevice.id, privacy: .public)"
            )
            return
        }

        guard newDevice.id != previousDevice.id else {
            Self.refreshCaptureFormat(for: newDevice, writer: writer)
            return
        }

        let previousIOProcID = ioProcID
        let handoffStartedAt = Date()
        formatObserver.stop()
        if let previousIOProcID {
            AudioDeviceStop(previousDevice.id, previousIOProcID)
            AudioDeviceDestroyIOProcID(previousDevice.id, previousIOProcID)
        }
        drainIOCallbacks()
        writer.beginInputDiscontinuity()
        device = nil
        ioProcID = nil

        do {
            let newFormat = try Self.inputFormat(for: newDevice)
            writer.updateInputFormat(newFormat)
            let newIOProcID = try createIOProc(on: newDevice, writer: writer)
            try startIOProc(newIOProcID, on: newDevice)

            device = newDevice
            ioProcID = newIOProcID
            observeFormatChanges(on: newDevice, writer: writer)
            logger.info(
                "Microphone device switched from=\(previousDevice.id, privacy: .public) to=\(newDevice.id, privacy: .public) format=\(WiretapLog.audioFormatSummary(newFormat), privacy: .public) handoffSeconds=\(Date().timeIntervalSince(handoffStartedAt), privacy: .public)"
            )
        } catch {
            logger.error(
                "Microphone switch to device=\(newDevice.id, privacy: .public) failed error=\(error.localizedDescription, privacy: .public); attempting previous device=\(previousDevice.id, privacy: .public)"
            )
            do {
                let previousFormat = try Self.inputFormat(for: previousDevice)
                writer.updateInputFormat(previousFormat)
                let restoredIOProcID = try createIOProc(on: previousDevice, writer: writer)
                try startIOProc(restoredIOProcID, on: previousDevice)

                device = previousDevice
                ioProcID = restoredIOProcID
                observeFormatChanges(on: previousDevice, writer: writer)
                logger.warning(
                    "Microphone capture remained on previous device=\(previousDevice.id, privacy: .public) after default-device switch failed"
                )
            } catch {
                throw AudioRecordingError.deviceHandoffFailed(underlying: error)
            }
        }
    }

    private func createIOProc(
        on device: AudioHardwareDevice,
        writer: AudioBufferListFileWriter
    ) throws -> AudioDeviceIOProcID {
        var ioProcID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID,
            device.id,
            ioQueue
        ) { [weak writer] _, inputData, inputTime, _, _ in
            let sampleTime = inputTime.pointee.mFlags.contains(.sampleTimeValid)
                ? inputTime.pointee.mSampleTime
                : nil
            let bufferStartUptime = inputTime.pointee.mFlags.contains(.hostTimeValid)
                ? TimeInterval(AudioConvertHostTimeToNanos(inputTime.pointee.mHostTime)) / 1_000_000_000
                : nil
            writer?.write(
                inputData: inputData,
                sampleTime: sampleTime,
                bufferStartUptime: bufferStartUptime
            )
        }
        guard status == noErr, let ioProcID else {
            throw CoreAudioStatusError(status: status, operation: "create microphone IOProc")
        }
        return ioProcID
    }

    private func startIOProc(
        _ ioProcID: AudioDeviceIOProcID,
        on device: AudioHardwareDevice
    ) throws {
        let status = AudioDeviceStart(device.id, ioProcID)
        guard status == noErr else {
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
            throw CoreAudioStatusError(status: status, operation: "start microphone IOProc")
        }
    }

    private func drainIOCallbacks() {
        guard DispatchQueue.getSpecific(key: ioQueueKey) != true else { return }
        ioQueue.sync {}
    }

    private func observeFormatChanges(
        on device: AudioHardwareDevice,
        writer: AudioBufferListFileWriter
    ) {
        formatObserver.start(observing: device.id) { [weak writer] in
            guard let writer else { return }
            Self.refreshCaptureFormat(for: device, writer: writer)
        }
    }

    private func updatePostProcessingForCurrentOutput() {
        let outputRoute: MicrophoneOutputRoute?
        do {
            outputRoute = try currentOutputRoute()
        } catch {
            outputRoute = nil
        }
        let requiredProcessing = MicrophoneCapturePolicy.postProcessing(for: outputRoute)
        if requiredProcessing == .soundIsolation {
            postProcessing = .soundIsolation
        }
        logger.info(
            "Microphone output route changed outputRoute=\(outputRoute?.name ?? "unknown", privacy: .private(mask: .hash)) postProcessing=\(self.postProcessing.rawValue, privacy: .public)"
        )
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

    private static func refreshCaptureFormat(
        for device: AudioHardwareDevice,
        writer: AudioBufferListFileWriter
    ) {
        guard let format = try? inputFormat(for: device) else { return }

        writer.updateInputFormat(format)
    }

    private static func inputFormat(for device: AudioHardwareDevice) throws -> AVAudioFormat {
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

    static func postProcessing(for outputRoute: MicrophoneOutputRoute?) -> MicrophonePostProcessing {
        mode(for: outputRoute) == .speakerProcessed ? .soundIsolation : .none
    }
}

enum AudioRecordingError: LocalizedError {
    case noDefaultInputDevice
    case unsupportedFormat
    case deviceHandoffFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .noDefaultInputDevice:
            "Wiretap could not find a default microphone input device."
        case .unsupportedFormat:
            "Wiretap could not start recording from the default microphone."
        case .deviceHandoffFailed:
            "Wiretap could not continue microphone capture after the default input device changed."
        }
    }
}
