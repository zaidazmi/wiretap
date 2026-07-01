import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @Bindable var store: WiretapStore

    var body: some View {
        VStack(spacing: 0) {
            MenuHeader(store: store)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                if let notice = store.notice {
                    MenuNoticeBanner(
                        notice: notice,
                        openRecovery: { recovery in
                            store.openSettings(for: recovery)
                            store.notice = nil
                        },
                        dismiss: { store.notice = nil }
                    )
                }

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
                    showLibrary()
                    store.isOnboardingPresented = true
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    showLibrary()
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
    }

    private func showLibrary() {
        NSApplication.shared.setActivationPolicy(.regular)
        openWindow(id: WiretapWindow.library)
        NSApplication.shared.activate(ignoringOtherApps: true)
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

private struct MenuNoticeBanner: View {
    let notice: WiretapNotice
    let openRecovery: (WiretapNoticeRecovery) -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: notice.recovery == nil ? "info.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(notice.recovery == nil ? Color.secondary : Color.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 3) {
                    Text(notice.title)
                        .font(.subheadline.weight(.semibold))
                    Text(notice.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }

            if let recovery = notice.recovery {
                Button {
                    openRecovery(recovery)
                } label: {
                    Label(recovery.buttonTitle, systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
    MenuBarView(store: .preview)
        .padding()
}
