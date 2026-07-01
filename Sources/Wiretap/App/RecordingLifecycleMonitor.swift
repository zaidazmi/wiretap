import AppKit
import Foundation

final class RecordingLifecycleMonitor {
    private typealias Observation = (center: NotificationCenter, token: NSObjectProtocol)

    private var observations: [Observation] = []

    @MainActor
    init(
        store: WiretapStore,
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        observe(
            NSApplication.willTerminateNotification,
            center: notificationCenter
        ) { [weak store] in
            store?.preserveInterruptedRecording(reason: .appTermination)
        }

        observe(
            NSWorkspace.willSleepNotification,
            center: workspaceNotificationCenter
        ) { [weak store] in
            store?.interruptRecording(reason: .systemSleep)
        }

        observe(
            NSWorkspace.sessionDidResignActiveNotification,
            center: workspaceNotificationCenter
        ) { [weak store] in
            store?.interruptRecording(reason: .sessionInactive)
        }
    }

    deinit {
        for observation in observations {
            observation.center.removeObserver(observation.token)
        }
    }

    private func observe(
        _ name: Notification.Name,
        center: NotificationCenter,
        action: @MainActor @escaping () -> Void
    ) {
        let token = center.addObserver(
            forName: name,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                action()
            }
        }

        observations.append((center, token))
    }
}
