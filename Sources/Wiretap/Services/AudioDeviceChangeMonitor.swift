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
    private let stateLock = NSLock()
    private let delivery = AudioDeviceChangeBatcher()
    private var registrations: [Registration] = []
    private var activeGeneration: UInt64?

    func start(onChange: @escaping AudioDeviceChangeHandler) {
        stop()
        let generation = delivery.begin(onChange: onChange)
        stateLock.withLock {
            activeGeneration = generation
        }

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
                self?.delivery.schedule(change, generation: generation)
            }
            let status = AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                queue,
                listener
            )

            if status == noErr {
                let registration = Registration(address: address, listener: listener)
                let shouldKeep = stateLock.withLock {
                    guard activeGeneration == generation else { return false }
                    registrations.append(registration)
                    return true
                }
                if !shouldKeep {
                    remove(registration)
                }
            }
        }
    }

    func stop() {
        let registrations = stateLock.withLock {
            activeGeneration = nil
            let registrations = self.registrations
            self.registrations.removeAll()
            return registrations
        }
        delivery.stop()
        registrations.forEach(remove)
    }

    deinit {
        stop()
    }

    private func remove(_ registration: Registration) {
        var address = registration.address
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            registration.listener
        )
    }
}

/// Coalesces the burst of Core Audio notifications produced by a route change.
///
/// Its generation token prevents callbacks that were already queued when a
/// monitor stopped or restarted from reaching the new recording session.
final class AudioDeviceChangeBatcher: @unchecked Sendable {
    private let queue: DispatchQueue
    private let delay: DispatchTimeInterval
    private let stateLock = NSLock()
    private var generation: UInt64 = 0
    private var handler: AudioDeviceChangeHandler?
    private var pendingChanges: Set<AudioDeviceChange> = []
    private var pendingDelivery: DispatchWorkItem?

    init(
        queue: DispatchQueue = DispatchQueue(
            label: "dev.zaidazmi.Wiretap.audio-device-change-delivery"
        ),
        delay: DispatchTimeInterval = .milliseconds(250)
    ) {
        self.queue = queue
        self.delay = delay
    }

    @discardableResult
    func begin(onChange: @escaping AudioDeviceChangeHandler) -> UInt64 {
        stateLock.withLock {
            generation &+= 1
            pendingDelivery?.cancel()
            pendingDelivery = nil
            pendingChanges.removeAll()
            handler = onChange
            return generation
        }
    }

    func schedule(_ change: AudioDeviceChange, generation: UInt64) {
        let delivery = stateLock.withLock { () -> DispatchWorkItem? in
            guard self.generation == generation, handler != nil else { return nil }

            pendingChanges.insert(change)
            pendingDelivery?.cancel()
            let delivery = DispatchWorkItem { [weak self] in
                self?.deliver(generation: generation)
            }
            pendingDelivery = delivery
            return delivery
        }

        if let delivery {
            queue.asyncAfter(deadline: .now() + delay, execute: delivery)
        }
    }

    func stop() {
        stateLock.withLock {
            generation &+= 1
            pendingDelivery?.cancel()
            pendingDelivery = nil
            pendingChanges.removeAll()
            handler = nil
        }
    }

    private func deliver(generation: UInt64) {
        let delivery = stateLock.withLock { () -> (
            changes: Set<AudioDeviceChange>,
            handler: AudioDeviceChangeHandler
        )? in
            guard self.generation == generation, let handler else { return nil }

            let changes = pendingChanges
            pendingChanges.removeAll()
            pendingDelivery = nil
            return (changes, handler)
        }
        guard let delivery else { return }

        // Update output policy before rebinding input when Bluetooth changes
        // both defaults in the same Core Audio notification burst.
        let orderedChanges: [AudioDeviceChange] = [.defaultOutput, .defaultInput]
        Task { @MainActor [weak self] in
            for change in orderedChanges where delivery.changes.contains(change) {
                guard self?.isActive(generation: generation) == true else { return }
                delivery.handler(change)
            }
        }
    }

    private func isActive(generation: UInt64) -> Bool {
        stateLock.withLock {
            self.generation == generation && handler != nil
        }
    }
}
