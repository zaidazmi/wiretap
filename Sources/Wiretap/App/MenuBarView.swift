import SwiftUI

struct MenuBarView: View {
    @Bindable var store: WiretapStore
    let libraryWindowController: LibraryWindowController

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader(store: store)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                MenuRecordingPanel(store: store)
                RecordingControlsView(store: store)
                MenuCaptureSources(
                    permissionState: store.permissionState,
                    permissionTitle: store.capturePermissionTitle,
                    systemAudioState: store.systemAudioState,
                    microphoneState: store.microphoneState
                )
            }
            .padding(16)

            Divider()

            VStack(spacing: 8) {
                Button {
                    store.isOnboardingPresented = true
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    libraryWindowController.show(store: store)
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
            .padding(16)
        }
        .frame(width: 360)
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
        .task(id: store.isRecording) {
            while store.isRecording {
                store.tick()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

private struct MenuHeader: View {
    let store: WiretapStore

    var body: some View {
        HStack(spacing: 12) {
            RecordingStatusBadge(isRecording: store.isRecording)

            VStack(alignment: .leading, spacing: 3) {
                Text("Wiretap")
                    .font(.headline)
                Text(store.recordingSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(store.isRecording ? "Live" : "Idle")
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.isRecording ? .red : .secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(store.isRecording ? Color.red.opacity(0.12) : Color.secondary.opacity(0.12))
                )
        }
        .padding(16)
    }
}

private struct MenuRecordingPanel: View {
    let store: WiretapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.recordingTitle)
                .font(.subheadline.weight(.semibold))

            Text(store.isRecording ? store.elapsedText : "00:00")
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            HStack(spacing: 10) {
                MenuMetric(title: "Recordings", value: "\(store.recordings.count)")
                MenuMetric(title: "Library", value: store.totalFileSizeText)
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MenuMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MenuCaptureSources: View {
    let permissionState: PermissionState
    let permissionTitle: String
    let systemAudioState: CaptureSourceState
    let microphoneState: CaptureSourceState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Capture")
                .font(.subheadline.weight(.semibold))

            SourceRow(
                title: "System audio",
                systemImage: "speaker.wave.2.fill",
                state: systemAudioState
            )
            SourceRow(
                title: "Default microphone",
                systemImage: "mic.fill",
                state: microphoneState
            )

            HStack {
                Image(systemName: permissionState == .ready ? "checkmark.shield.fill" : "lock.shield")
                    .foregroundStyle(systemAudioState == .unavailable ? .orange : permissionState == .ready ? .green : .secondary)
                Text(permissionTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
    }
}

private struct SourceRow: View {
    let title: String
    let systemImage: String
    let state: CaptureSourceState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            Text(title)
                .font(.callout)
            Spacer()
            Image(systemName: stateIcon)
                .foregroundStyle(stateColor)
                .help(state.label)
        }
    }

    private var stateIcon: String {
        switch state {
        case .notChecked: "circle"
        case .ready: "checkmark.circle.fill"
        case .unavailable: "exclamationmark.circle.fill"
        }
    }

    private var stateColor: Color {
        switch state {
        case .notChecked: .secondary
        case .ready: .green
        case .unavailable: .orange
        }
    }
}

#Preview {
    MenuBarView(store: .preview, libraryWindowController: LibraryWindowController())
        .padding()
}
