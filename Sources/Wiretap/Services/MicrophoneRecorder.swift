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
    private var writer: AudioBufferListFileWriter?
    private var postProcessing: MicrophonePostProcessing = .none
    private var startedAt: Date?
    private lazy var formatObserver = AudioDeviceFormatObserver(queue: ioQueue)
    private let logger = WiretapLog.capture

    var isRecording: Bool {
        ioProcID != nil
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
        let inputFormat = try inputFormat(for: device)
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
        logger.info("Microphone capture started mode=physical-device device=\(device.id, privacy: .public) postProcessing=\(postProcessing.rawValue, privacy: .public)")
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

    var errorDescription: String? {
        switch self {
        case .noDefaultInputDevice:
            "Wiretap could not find a default microphone input device."
        case .unsupportedFormat:
            "Wiretap could not start recording from the default microphone."
        }
    }
}
