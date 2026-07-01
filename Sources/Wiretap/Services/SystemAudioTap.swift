import AVFoundation
import CoreAudio
import Foundation

final class SystemAudioTap {
    private let system = AudioHardwareSystem.shared
    private let ioQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.system-audio-tap", qos: .userInitiated)
    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var writer: AudioBufferListFileWriter?

    var isRunning: Bool {
        ioProcID != nil
    }

    func start(writingTo outputURL: URL) throws {
        guard !isRunning else { return }

        do {
            let excludedProcesses = try currentProcessExclusionList()
            let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: excludedProcesses)
            tapDescription.name = "Wiretap System Audio"
            tapDescription.isPrivate = true
            tapDescription.muteBehavior = .unmuted

            guard let tap = try system.makeProcessTap(description: tapDescription) else {
                throw SystemAudioTapError.tapCreationFailed
            }

            var streamDescription = try tap.format
            guard let inputFormat = AVAudioFormat(streamDescription: &streamDescription) else {
                try system.destroyProcessTap(tap)
                throw SystemAudioTapError.unsupportedFormat
            }

            let writer = try AudioBufferListFileWriter(outputURL: outputURL, inputFormat: inputFormat)

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Wiretap System Audio Device",
                kAudioAggregateDeviceUIDKey: "dev.zaidazmi.Wiretap.Aggregate.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: try tap.uid]],
                kAudioAggregateDeviceTapAutoStartKey: true
            ]

            guard let aggregateDevice = try system.makeAggregateDevice(description: aggregateDescription) else {
                try system.destroyProcessTap(tap)
                throw SystemAudioTapError.aggregateCreationFailed
            }

            self.tap = tap
            self.aggregateDevice = aggregateDevice
            self.writer = writer

            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDevice.id,
                ioQueue
            ) { [weak self] _, inputData, _, _, _ in
                self?.writer?.write(inputData: inputData)
            }

            guard createStatus == noErr, let ioProcID else {
                throw CoreAudioStatusError(status: createStatus, operation: "create tap IOProc")
            }

            let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
                throw CoreAudioStatusError(status: startStatus, operation: "start tap IOProc")
            }

            self.ioProcID = ioProcID
        } catch {
            let mappedError = SystemAudioTapError.map(error)
            stop()
            throw mappedError
        }
    }

    func stop() {
        if let aggregateDevice, let ioProcID {
            AudioDeviceStop(aggregateDevice.id, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
        }

        if let aggregateDevice {
            try? system.destroyAggregateDevice(aggregateDevice)
        }

        if let tap {
            try? system.destroyProcessTap(tap)
        }

        writer?.flush()
        ioProcID = nil
        aggregateDevice = nil
        tap = nil
        writer = nil
    }

    private func currentProcessExclusionList() throws -> [AudioObjectID] {
        if let process = try system.process(for: getpid()) {
            return [process.id]
        }

        return []
    }

}

enum SystemAudioTapError: LocalizedError {
    case permissionDenied
    case tapCreationFailed
    case aggregateCreationFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Wiretap does not have permission to capture system audio."
        case .tapCreationFailed:
            "Wiretap could not create the private system-audio process tap."
        case .aggregateCreationFailed:
            "Wiretap could not create the private aggregate device for the system-audio tap."
        case .unsupportedFormat:
            "Wiretap could not read the system-audio tap format."
        }
    }

    static func map(_ error: Error) -> Error {
        if isPermissionDenied(error) {
            return SystemAudioTapError.permissionDenied
        }

        return error
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        if case SystemAudioTapError.permissionDenied = error {
            return true
        }

        if let error = error as? AudioHardwareError {
            return error.error == kAudioDevicePermissionsError
        }

        if let error = error as? CoreAudioStatusError {
            return error.status == kAudioDevicePermissionsError
        }

        return false
    }
}

struct CoreAudioStatusError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "Core Audio failed to \(operation) (OSStatus \(status))."
    }
}
