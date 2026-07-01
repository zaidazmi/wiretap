import SwiftUI

@main
struct WiretapApp: App {
    @State private var store = WiretapStore.live()
    private let libraryWindowController = LibraryWindowController()

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
