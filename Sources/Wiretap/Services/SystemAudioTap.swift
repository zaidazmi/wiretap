import AVFoundation
import CoreAudio
import Foundation

final class SystemAudioTap {
    private let system = AudioHardwareSystem.shared
    private let ioQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.system-audio-tap", qos: .userInitiated)
    private var tap: AudioHardwareTap?
    private var aggregateDevice: AudioHardwareAggregateDevice?
    private var ioProcID: AudioDeviceIOProcID?
    private var inputFormat: AVAudioFormat?
    private var audioFile: AVAudioFile?

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

            let channelCount = max(1, Int(inputFormat.channelCount))
            let outputSettings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: inputFormat.sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
            let audioFile = try AVAudioFile(forWriting: outputURL, settings: outputSettings)

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

            var ioProcID: AudioDeviceIOProcID?
            let createStatus = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateDevice.id,
                ioQueue
            ) { [weak self] _, inputData, _, _, _ in
                self?.write(inputData: inputData)
            }

            guard createStatus == noErr, let ioProcID else {
                try system.destroyAggregateDevice(aggregateDevice)
                try system.destroyProcessTap(tap)
                throw CoreAudioStatusError(status: createStatus, operation: "create tap IOProc")
            }

            let startStatus = AudioDeviceStart(aggregateDevice.id, ioProcID)
            guard startStatus == noErr else {
                AudioDeviceDestroyIOProcID(aggregateDevice.id, ioProcID)
                try system.destroyAggregateDevice(aggregateDevice)
                try system.destroyProcessTap(tap)
                throw CoreAudioStatusError(status: startStatus, operation: "start tap IOProc")
            }

            self.tap = tap
            self.aggregateDevice = aggregateDevice
            self.ioProcID = ioProcID
            self.inputFormat = inputFormat
            self.audioFile = audioFile
        } catch {
            stop()
            throw error
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

        ioProcID = nil
        aggregateDevice = nil
        tap = nil
        inputFormat = nil
        audioFile = nil
    }

    private func currentProcessExclusionList() throws -> [AudioObjectID] {
        if let process = try system.process(for: getpid()) {
            return [process.id]
        }

        return []
    }

    private func write(inputData: UnsafePointer<AudioBufferList>) {
        guard let inputFormat,
              let audioFile,
              let firstBuffer = UnsafeMutableAudioBufferListPointer(
                UnsafeMutablePointer(mutating: inputData)
              ).first
        else { return }

        let streamDescription = inputFormat.streamDescription.pointee
        let bytesPerFrame = max(1, Int(streamDescription.mBytesPerFrame))
        let frameLength = AVAudioFrameCount(Int(firstBuffer.mDataByteSize) / bytesPerFrame)
        guard frameLength > 0,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                bufferListNoCopy: UnsafeMutablePointer(mutating: inputData),
                deallocator: nil
              )
        else { return }

        buffer.frameLength = frameLength
        try? audioFile.write(from: buffer)
    }
}

enum SystemAudioTapError: LocalizedError {
    case tapCreationFailed
    case aggregateCreationFailed
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .tapCreationFailed:
            "Wiretap could not create the private system-audio process tap."
        case .aggregateCreationFailed:
            "Wiretap could not create the private aggregate device for the system-audio tap."
        case .unsupportedFormat:
            "Wiretap could not read the system-audio tap format."
        }
    }
}

struct CoreAudioStatusError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "Core Audio failed to \(operation) (OSStatus \(status))."
    }
}
