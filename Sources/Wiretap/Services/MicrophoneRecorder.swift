import AVFoundation
import CoreAudio
import Foundation

final class MicrophoneRecorder {
    private let system = AudioHardwareSystem.shared
    private let ioQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.microphone-recorder", qos: .userInitiated)
    private var device: AudioHardwareDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioBufferListFileWriter?
    private var startedAt: Date?

    var isRecording: Bool {
        ioProcID != nil
    }

    func startRecording(to url: URL) throws {
        stopRecording()

        do {
            guard let device = try system.defaultInputDevice else {
                throw AudioRecordingError.noDefaultInputDevice
            }

            let inputFormat = try inputFormat(for: device)
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
        } catch {
            stopRecording()
            throw error
        }
    }

    @discardableResult
    func stopRecording() -> TimeInterval {
        if let device, let ioProcID {
            AudioDeviceStop(device.id, ioProcID)
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
        }

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        writer?.flush()
        device = nil
        ioProcID = nil
        writer = nil
        startedAt = nil
        return duration
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
