import SwiftUI

@main
@MainActor
struct WiretapApp: App {
    @State private var store: WiretapStore
    private let libraryWindowController = LibraryWindowController()
    private let lifecycleMonitor: RecordingLifecycleMonitor

    init() {
        let store = WiretapStore.live()
        self._store = State(initialValue: store)
        self.lifecycleMonitor = RecordingLifecycleMonitor(store: store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store, libraryWindowController: libraryWindowController)
        } label: {
            Image(systemName: store.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(store.isRecording ? .multicolor : .hierarchical)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Open Library") {
                    libraryWindowController.show(store: store)
                }
                .keyboardShortcut("l", modifiers: [.command])
            }
        }
    }
}
