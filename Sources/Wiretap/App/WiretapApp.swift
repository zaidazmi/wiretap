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
            Image(systemName: store.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(store.isRecording ? .multicolor : .hierarchical)
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

                Button("Open Library") {
                    openWindow(id: WiretapWindow.library)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }
    }
}
