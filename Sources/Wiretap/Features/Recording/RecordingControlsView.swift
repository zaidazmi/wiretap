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
            .tint(.red)
            .disabled(store.isRecording || !store.canRecord)

            Button {
                store.stopRecording()
            } label: {
                Label("Stop", systemImage: "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(!store.isRecording)
        }
    }
}
