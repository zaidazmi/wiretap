import CoreAudio
import Foundation

/// Watches a capture device for stream-format changes while recording.
///
/// Bluetooth headsets renegotiate their codec when the microphone side
/// activates (A2DP → HFP), which silently drops the device's sample rate
/// mid-capture. The default-device monitor never fires for this because the
/// device identity is unchanged, so capture sources observe the device's
/// nominal sample rate and input-stream list directly.
final class AudioDeviceFormatObserver: @unchecked Sendable {
    private struct Registration {
        enum Kind {
            case device
            case stream
        }

        var objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
        var kind: Kind
    }

    private let queue: DispatchQueue
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var registrations: [Registration] = []

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    deinit {
        stop()
    }

    func start(
        observing deviceID: AudioObjectID,
        onChange: @escaping @Sendable () -> Void
    ) {
        stop()
        let generation = stateLock.withLock {
            self.generation &+= 1
            return self.generation
        }

        for address in Self.devicePropertyAddresses {
            addRegistration(
                objectID: deviceID,
                address: address,
                generation: generation,
                onChange: onChange,
                kind: .device,
                refreshStreamRegistrations: Self.shouldRefreshStreamRegistrations(
                    for: address
                ),
                deviceID: deviceID
            )
        }

        for streamID in inputStreamIDs(for: deviceID) {
            addRegistration(
                objectID: streamID,
                address: Self.streamVirtualFormatAddress,
                generation: generation,
                onChange: onChange,
                kind: .stream,
                refreshStreamRegistrations: false,
                deviceID: deviceID
            )
        }
    }

    func stop() {
        let registrations = stateLock.withLock {
            generation &+= 1
            let registrations = self.registrations
            self.registrations.removeAll()
            return registrations
        }

        registrations.forEach(remove)
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

    static func shouldRefreshStreamRegistrations(
        for address: AudioObjectPropertyAddress
    ) -> Bool {
        address.mSelector == kAudioDevicePropertyStreams
            && address.mScope == kAudioObjectPropertyScopeInput
    }

    private func addRegistration(
        objectID: AudioObjectID,
        address: AudioObjectPropertyAddress,
        generation: UInt64,
        onChange: @escaping @Sendable () -> Void,
        kind: Registration.Kind,
        refreshStreamRegistrations: Bool,
        deviceID: AudioObjectID
    ) {
        var mutableAddress = address
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            performIfActive(generation: generation, onChange)

            if refreshStreamRegistrations {
                queue.async { [weak self] in
                    self?.refreshInputStreamRegistrations(
                        for: deviceID,
                        generation: generation,
                        onChange: onChange
                    )
                }
            }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            objectID,
            &mutableAddress,
            queue,
            block
        )
        if status == noErr {
            let registration = Registration(
                objectID: objectID,
                address: mutableAddress,
                block: block,
                kind: kind
            )
            let shouldKeep = stateLock.withLock {
                guard self.generation == generation else { return false }
                registrations.append(registration)
                return true
            }
            if !shouldKeep {
                remove(registration)
            }
        }
    }

    private func refreshInputStreamRegistrations(
        for deviceID: AudioObjectID,
        generation: UInt64,
        onChange: @escaping @Sendable () -> Void
    ) {
        let previousStreamRegistrations = stateLock.withLock { () -> [Registration]? in
            guard self.generation == generation else { return nil }

            let streamRegistrations = registrations.filter { $0.kind == .stream }
            registrations.removeAll { $0.kind == .stream }
            return streamRegistrations
        }
        guard let previousStreamRegistrations else { return }

        previousStreamRegistrations.forEach(remove)
        for streamID in inputStreamIDs(for: deviceID) {
            addRegistration(
                objectID: streamID,
                address: Self.streamVirtualFormatAddress,
                generation: generation,
                onChange: onChange,
                kind: .stream,
                refreshStreamRegistrations: false,
                deviceID: deviceID
            )
        }
    }

    private func performIfActive(
        generation: UInt64,
        _ action: @Sendable () -> Void
    ) {
        stateLock.withLock {
            guard self.generation == generation else { return }
            // Keep stop/start mutually exclusive with the callback body so an
            // old device cannot overwrite the new device's input format after
            // a handoff has begun.
            action()
        }
    }

    private func remove(_ registration: Registration) {
        var address = registration.address
        AudioObjectRemovePropertyListenerBlock(
            registration.objectID,
            &address,
            queue,
            registration.block
        )
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
