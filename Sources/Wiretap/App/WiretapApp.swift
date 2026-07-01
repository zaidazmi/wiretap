import SwiftUI

@main
struct WiretapApp: App {
    @State private var store = WiretapStore.preview

    var body: some Scene {
        WindowGroup("Wiretap Library", id: "library") {
            LibraryView(store: store)
                .frame(minWidth: 920, minHeight: 620)
        }
        .defaultSize(width: 1080, height: 720)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(store.isRecording ? "Stop Recording" : "Start Recording") {
                    store.toggleRecording()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(store: store)
        } label: {
            Image(systemName: store.isRecording ? "record.circle.fill" : "waveform.circle")
                .symbolRenderingMode(store.isRecording ? .multicolor : .hierarchical)
        }
        .menuBarExtraStyle(.window)
    }
}
