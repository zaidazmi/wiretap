import CoreAudio
import Foundation

typealias AudioDeviceChangeHandler = @MainActor @Sendable () -> Void

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

    func start(onChange: @escaping AudioDeviceChangeHandler) {
        stop()

        for selector in [
            kAudioHardwarePropertyDefaultInputDevice,
            kAudioHardwarePropertyDefaultOutputDevice
        ] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let listener: AudioObjectPropertyListenerBlock = { _, _ in
                Task { @MainActor in
                    onChange()
                }
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
}
