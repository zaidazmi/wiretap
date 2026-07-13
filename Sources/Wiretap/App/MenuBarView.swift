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
                            store.resolveNoticeRecovery(recovery)
                        },
                        dismiss: { store.dismissNotice() }
                    )
                }

                MenuRecordingPanel(store: store)
                RecordingControlsView(store: store)
                MenuCaptureSources(store: store)
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
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.permissionsButton)

                Button {
                    showLibrary()
                } label: {
                    Label("Open Library", systemImage: "rectangle.stack")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.openLibraryButton)

                Button(role: .destructive) {
                    NSApplication.shared.terminate(nil)
                } label: {
                    Label("Quit Wiretap", systemImage: "power")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.quitButton)
            }
            .buttonStyle(.plain)
            .padding(16)
        }
        .frame(width: 360)
        .accessibilityIdentifier(WiretapAccessibility.MenuBar.panel)
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
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.status)
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
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.elapsed)

            HStack(spacing: 10) {
                MenuMetric(
                    title: "Recordings",
                    value: "\(store.recordings.count)",
                    identifier: WiretapAccessibility.MenuBar.recordingCount
                )
                MenuMetric(
                    title: "Library",
                    value: store.totalFileSizeText,
                    identifier: WiretapAccessibility.MenuBar.librarySize
                )
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MenuMetric: View {
    let title: String
    let value: String
    let identifier: String

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
        .accessibilityIdentifier(identifier)
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
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.noticeDismissButton)
            }

            if let recovery = notice.recovery {
                Button {
                    openRecovery(recovery)
                } label: {
                    Label(recovery.buttonTitle, systemImage: "gear")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier(WiretapAccessibility.MenuBar.noticeRecoveryButton)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(WiretapAccessibility.MenuBar.noticeBanner)
    }
}

private struct MenuCaptureSources: View {
    @Bindable var store: WiretapStore

    var body: some View {
        HStack {
            Image(systemName: isPermissionReady ? "checkmark.shield.fill" : "lock.shield")
                .foregroundStyle(store.systemAudioState == .unavailable ? .orange : isPermissionReady ? .green : .secondary)
            Text(store.capturePermissionTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var isPermissionReady: Bool {
        store.permissionState == .ready
    }
}

#Preview {
    MenuBarView(store: .preview)
        .padding()
}
