import CoreAudio
import Foundation

/// Watches a capture device for stream-format changes while recording.
///
/// Bluetooth headsets renegotiate their codec when the microphone side
/// activates (A2DP → HFP), which silently drops the device's sample rate
/// mid-capture. The default-device monitor never fires for this because the
/// device identity is unchanged, so capture sources observe the device's
/// nominal sample rate and input-stream list directly.
final class AudioDeviceFormatObserver {
    private struct Registration {
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private let queue: DispatchQueue
    private var deviceID: AudioObjectID?
    private var registrations: [Registration] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start(observing deviceID: AudioObjectID, onChange: @escaping () -> Void) {
        stop()
        self.deviceID = deviceID

        let addresses = [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
        ]

        for var address in addresses {
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                onChange()
            }
            let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, block)
            if status == noErr {
                registrations.append(Registration(address: address, block: block))
            }
        }
    }

    func stop() {
        if let deviceID {
            for registration in registrations {
                var address = registration.address
                AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, registration.block)
            }
        }
        registrations.removeAll()
        deviceID = nil
    }
}
