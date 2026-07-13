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
        var objectID: AudioObjectID
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

        for address in Self.devicePropertyAddresses {
            addRegistration(objectID: deviceID, address: address, onChange: onChange)
        }

        for streamID in inputStreamIDs(for: deviceID) {
            addRegistration(
                objectID: streamID,
                address: Self.streamVirtualFormatAddress,
                onChange: onChange
            )
        }
    }

    func stop() {
        for registration in registrations {
            var address = registration.address
            AudioObjectRemovePropertyListenerBlock(
                registration.objectID,
                &address,
                queue,
                registration.block
            )
        }
        registrations.removeAll()
        deviceID = nil
    }

    static var devicePropertyAddresses: [AudioObjectPropertyAddress] {
        [
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyNominalSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyActualSampleRate,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            ),
            AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceHasChanged,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
        ]
    }

    static var streamVirtualFormatAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioStreamPropertyVirtualFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func addRegistration(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        onChange: @escaping () -> Void
    ) {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            onChange()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        )
        if status == noErr {
            registrations.append(
                Registration(objectID: objectID, address: mutableAddress, block: block)
            )
        }
    }

    private func inputStreamIDs(for deviceID: AudioObjectID) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= UInt32(MemoryLayout<AudioObjectID>.size)
        else { return [] }

        var streams = [AudioObjectID](
            repeating: kAudioObjectUnknown,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        let status = streams.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &dataSize,
                bytes.baseAddress!
            )
        }
        return status == noErr ? streams : []
    }
}
