import SwiftUI

@main
@MainActor
struct WiretapApp: App {
    @Environment(\.openWindow) private var openWindow

    @State private var store: WiretapStore
    private let lifecycleMonitor: RecordingLifecycleMonitor
    private let timelineTicker: RecordingTimelineTicker

    init() {
        let store = WiretapStore.live()
        self._store = State(initialValue: store)
        self.lifecycleMonitor = RecordingLifecycleMonitor(store: store)
        self.timelineTicker = RecordingTimelineTicker(store: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            MenuBarLabelView(store: store)
        }
        .menuBarExtraStyle(.window)

        Window("Wiretap Library", id: WiretapWindow.library) {
            WiretapLibraryWindowView(store: store)
        }
        .defaultSize(width: 1180, height: 760)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .accessibilityIdentifier(WiretapAccessibility.Command.recordToggle)

                Button("Open Library") {
                    openWindow(id: WiretapWindow.library)
                }
                .keyboardShortcut("l", modifiers: [.command])
                .accessibilityIdentifier(WiretapAccessibility.Command.openLibrary)
            }
        }
    }
}

private struct MenuBarLabelView: View {
    @Environment(\.openWindow) private var openWindow
    let store: WiretapStore
    @State private var didOpenInitialPermissions = false

    var body: some View {
        Image(systemName: store.isRecording ? "record.circle.fill" : "waveform.circle")
            .symbolRenderingMode(store.isRecording ? .multicolor : .hierarchical)
            .accessibilityIdentifier(WiretapAccessibility.MenuBar.statusItem)
            .task {
                openInitialPermissionsIfNeeded()
            }
            .onChange(of: store.isOnboardingPresented) {
                openInitialPermissionsIfNeeded()
            }
    }

    private func openInitialPermissionsIfNeeded() {
        guard store.isOnboardingPresented, !didOpenInitialPermissions else { return }

        didOpenInitialPermissions = true
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: WiretapWindow.library)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
