import SwiftUI

enum RecordingControlStyle {
    case toolbar
    case menuBar
}

struct RecordingControlView: View {
    @Bindable var store: WiretapStore
    let style: RecordingControlStyle

    var body: some View {
        if style == .menuBar || store.isRecording {
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
        .disabled(!store.isRecording && !store.canRecord)
        .help(buttonTitle)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var buttonTitle: String {
        if store.isRecording {
            return style == .menuBar ? "Stop \(store.elapsedText)" : "Stop Recording"
        }

        return "Record"
    }

    private var accessibilityIdentifier: String {
        switch style {
        case .toolbar:
            WiretapAccessibility.Library.toolbarRecordButton
        case .menuBar:
            WiretapAccessibility.MenuBar.recordButton
        }
    }
}

struct RecordingStatusBadge: View {
    let isRecording: Bool

    var body: some View {
        if isRecording {
            LiveRecordingGlyph(size: 36)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.green)
        }
    }
}

#Preview {
    VStack {
        RecordingControlView(store: .preview, style: .toolbar)
        RecordingControlView(store: .preview, style: .menuBar)
    }
    .padding()
}
