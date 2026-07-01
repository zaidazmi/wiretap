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
            .alert(item: $store.notice) { notice in
                if let recovery = notice.recovery {
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        primaryButton: .default(Text(recovery.buttonTitle)) {
                            store.openSettings(for: recovery)
                        },
                        secondaryButton: .cancel(Text("OK"))
                    )
                } else {
                    Alert(
                        title: Text(notice.title),
                        message: Text(notice.message),
                        dismissButton: .default(Text("OK"))
                    )
                }
            }
    }
}

extension View {
    func wiretapPresentation(store: WiretapStore) -> some View {
        modifier(WiretapPresentationModifier(store: store))
    }
}
