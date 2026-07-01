import SwiftUI

struct MenuBarView: View {
    @Bindable var store: WiretapStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                RecordingStatusBadge(isRecording: store.isRecording)

                VStack(alignment: .leading, spacing: 4) {
                    Text(store.isRecording ? "Recording" : "Ready")
                        .font(.headline)
                    Text(store.isRecording ? store.elapsedText : "System output + default mic")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Spacer()
            }

            RecordingControlsView(store: store)

            Divider()

            RecordingPermissionsView()

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    openWindow(id: "library")
                } label: {
                    Label("Open Library", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Wiretap", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(width: 320)
        .task(id: store.isRecording) {
            while store.isRecording {
                store.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

#Preview {
    MenuBarView(store: .preview)
        .padding()
}
