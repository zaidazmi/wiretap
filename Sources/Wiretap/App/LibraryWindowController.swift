import AppKit
import SwiftUI

@MainActor
final class LibraryWindowController {
    private var window: NSWindow?

    func show(store: WiretapStore) {
        let libraryWindow = window ?? makeWindow(store: store)
        window = libraryWindow

        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)

        if libraryWindow.isMiniaturized {
            libraryWindow.deminiaturize(nil)
        }

        libraryWindow.makeKeyAndOrderFront(nil)
        libraryWindow.orderFrontRegardless()
    }

    private func makeWindow(store: WiretapStore) -> NSWindow {
        let rootView = LibraryView(store: store)
            .frame(minWidth: 1040, minHeight: 680)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Wiretap Library"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: rootView)

        return window
    }
}
