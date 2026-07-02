import AppKit
import SwiftUI

struct WiretapLibraryWindowView: View {
    @Bindable var store: WiretapStore

    var body: some View {
        LibraryView(store: store)
            .frame(minWidth: 1040, minHeight: 680)
            .wiretapPresentation(store: store)
            .onAppear(perform: activateWindowMode)
            .onDisappear(perform: returnToMenuBarMode)
    }

    private func activateWindowMode() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    private func returnToMenuBarMode() {
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

private struct WiretapPresentationModifier: ViewModifier {
    @Bindable var store: WiretapStore

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $store.isOnboardingPresented) {
                OnboardingView(store: store)
            }
    }
}

extension View {
    func wiretapPresentation(store: WiretapStore) -> some View {
        modifier(WiretapPresentationModifier(store: store))
    }
}
