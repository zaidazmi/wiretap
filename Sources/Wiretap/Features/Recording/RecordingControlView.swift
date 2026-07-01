import SwiftUI

enum RecordingControlStyle {
    case toolbar
    case menuBar
}

struct RecordingControlView: View {
    @Bindable var store: WiretapStore
    let style: RecordingControlStyle

    var body: some View {
        if style == .menuBar {
            controlButton
                .buttonStyle(.borderedProminent)
        } else {
            controlButton
                .buttonStyle(.bordered)
        }
    }

    private var controlButton: some View {
        Button {
            store.toggleRecording()
        } label: {
            Label(buttonTitle, systemImage: store.isRecording ? "stop.fill" : "record.circle")
                .frame(maxWidth: style == .menuBar ? .infinity : nil)
        }
        .tint(store.isRecording ? .red : .accentColor)
        .disabled(!store.canRecord)
        .help(buttonTitle)
    }

    private var buttonTitle: String {
        if store.isRecording {
            return style == .menuBar ? "Stop \(store.elapsedText)" : "Stop"
        }

        return "Record"
    }
}

struct RecordingStatusBadge: View {
    let isRecording: Bool

    var body: some View {
        Image(systemName: isRecording ? "record.circle.fill" : "checkmark.circle.fill")
            .font(.system(size: 30, weight: .semibold))
            .foregroundStyle(isRecording ? .red : .green)
            .symbolEffect(.pulse, isActive: isRecording)
    }
}

#Preview {
    VStack {
        RecordingControlView(store: .preview, style: .toolbar)
        RecordingControlView(store: .preview, style: .menuBar)
    }
    .padding()
}
