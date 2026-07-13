import CoreAudio
import Foundation

enum AudioDeviceChange: Sendable, Equatable, Hashable {
    case defaultInput
    case defaultOutput
}

typealias AudioDeviceChangeHandler = @MainActor @Sendable (AudioDeviceChange) -> Void

protocol AudioDeviceChangeMonitoring: AnyObject {
    func start(onChange: @escaping AudioDeviceChangeHandler)
    func stop()
}

final class AudioDeviceChangeMonitor: AudioDeviceChangeMonitoring {
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let listener: AudioObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "dev.zaidazmi.Wiretap.audio-device-change-monitor")
    private var registrations: [Registration] = []
    private var pendingChanges: Set<AudioDeviceChange> = []
    private var pendingDelivery: DispatchWorkItem?

    func start(onChange: @escaping AudioDeviceChangeHandler) {
        stop()

        for (selector, change) in [
            (kAudioHardwarePropertyDefaultInputDevice, AudioDeviceChange.defaultInput),
            (kAudioHardwarePropertyDefaultOutputDevice, AudioDeviceChange.defaultOutput)
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                self?.schedule(change: change, onChange: onChange)
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )

            if status == noErr {
                registrations.append(Registration(address: address, listener: listener))
            }
        }
    }

    func stop() {
        removeRegistrations()
    }

    deinit {
        removeRegistrations()
    }

    private func removeRegistrations() {
        pendingDelivery?.cancel()
        pendingDelivery = nil
        pendingChanges.removeAll()

        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                registration.listener
            )
        }

        registrations.removeAll()
    }

    private func schedule(
        change: AudioDeviceChange,
        onChange: @escaping AudioDeviceChangeHandler
    ) {
        pendingChanges.insert(change)
        pendingDelivery?.cancel()

        let delivery = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let changes = pendingChanges
            pendingChanges.removeAll()
            pendingDelivery = nil

            // Update the output policy before rebinding the input when a
            // Bluetooth route changes both defaults in the same Core Audio burst.
            let orderedChanges: [AudioDeviceChange] = [.defaultOutput, .defaultInput]
            Task { @MainActor in
                for change in orderedChanges where changes.contains(change) {
                    onChange(change)
                }
            }
        }
        pendingDelivery = delivery
        queue.asyncAfter(deadline: .now() + .milliseconds(250), execute: delivery)
    }
}
