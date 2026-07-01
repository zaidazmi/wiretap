import SwiftUI

struct RecordingControlsView: View {
    @Bindable var store: WiretapStore

    var body: some View {
        HStack(spacing: 8) {
            Button {
                store.startRecording()
            } label: {
                Label("Record", systemImage: "record.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.red)
            .disabled(store.isRecording || !store.canRecord)
            .accessibilityIdentifier(WiretapAccessibility.MenuBar.recordButton)

            Button {
                store.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(!store.isRecording)
            .accessibilityIdentifier(WiretapAccessibility.MenuBar.stopButton)
        }
    }
}
