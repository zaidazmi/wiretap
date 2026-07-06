import AVFoundation
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
    private var startedAt: Date?
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

            let inputFormat = try inputFormat(for: device)
            let deviceUID = (try? device.uid) ?? "unknown"
            logger.info(
                "Preparing microphone capture device=\(device.id, privacy: .public) uid=\(deviceUID, privacy: .private(mask: .hash)) format=\(WiretapLog.audioFormatSummary(inputFormat), privacy: .public) output=\(url.lastPathComponent, privacy: .public)"
            )
            let writer = try AudioBufferListFileWriter(outputURL: url, inputFormat: inputFormat)
            self.device = device
            self.writer = writer

            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                device.id,
                ioQueue
            ) { [weak self] _, inputData, _, _, _ in
                self?.writer?.write(inputData: inputData)
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
            self.startedAt = Date()
            logger.info("Microphone capture started device=\(device.id, privacy: .public)")
        } catch {
            logger.error("Microphone capture failed: \(error.localizedDescription, privacy: .public)")
            stopRecording()
            throw error
        }
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        let wasRecording = device != nil || writer != nil

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
        writer = nil
        startedAt = nil

        if wasRecording {
            logger.info(
                "Microphone capture stopped duration=\(result.duration, privacy: .public) capturedFrames=\(result.capturedFrameCount, privacy: .public) droppedFrames=\(result.droppedFrameCount, privacy: .public) writeError=\(result.writeError?.localizedDescription ?? "none", privacy: .public)"
            )
        }

        return result
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
