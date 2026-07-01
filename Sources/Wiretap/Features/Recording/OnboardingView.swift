import SwiftUI

struct OnboardingView: View {
    @Bindable var store: WiretapStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Wiretap")
                        .font(.largeTitle.weight(.semibold))
                    Text("System output audio and the default microphone.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 14) {
                PermissionRow(
                    title: "System Audio",
                    summary: "Captures the audio playing on this Mac, including headphone playback.",
                    systemImage: "speaker.wave.3.fill",
                    state: store.systemAudioState,
                    rowIdentifier: WiretapAccessibility.Onboarding.systemAudioRow,
                    statusIdentifier: WiretapAccessibility.Onboarding.systemAudioStatus
                )
                PermissionRow(
                    title: "Microphone",
                    summary: "Uses the current macOS default input device.",
                    systemImage: "mic.fill",
                    state: store.microphoneState,
                    rowIdentifier: WiretapAccessibility.Onboarding.microphoneRow,
                    statusIdentifier: WiretapAccessibility.Onboarding.microphoneStatus
                )
                PermissionRow(
                    title: "Local Files",
                    summary: "Saves mixed AAC .m4a recordings in the app library.",
                    systemImage: "externaldrive.fill",
                    state: .ready,
                    rowIdentifier: WiretapAccessibility.Onboarding.localFilesRow,
                    statusIdentifier: WiretapAccessibility.Onboarding.localFilesStatus
                )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.capturePermissionTitle)
                        .font(.headline)
                    Text(store.capturePermissionSummary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Not Now") {
                    dismiss()
                }
                .accessibilityIdentifier(WiretapAccessibility.Onboarding.notNowButton)

                Button("Refresh") {
                    store.refreshPermissions()
                }
                .accessibilityIdentifier(WiretapAccessibility.Onboarding.refreshButton)

                Button("Continue") {
                    Task {
                        await store.requestPermissions()
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier(WiretapAccessibility.Onboarding.continueButton)

                if store.permissionState == .denied || store.systemAudioState == .unavailable {
                    Button("Open Settings") {
                        if store.systemAudioState == .unavailable {
                            store.openSettings(for: .systemAudioSettings)
                        } else {
                            store.openPermissionSettings()
                        }
                        dismiss()
                    }
                    .accessibilityIdentifier(WiretapAccessibility.Onboarding.openSettingsButton)
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .accessibilityIdentifier(WiretapAccessibility.Onboarding.root)
    }
}

private struct PermissionRow: View {
    let title: String
    let summary: String
    let systemImage: String
    let state: CaptureSourceState
    let rowIdentifier: String
    let statusIdentifier: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(title)
                        .font(.headline)
                    Spacer()
                    Label(state.label, systemImage: stateIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(stateColor)
                        .help(state.label)
                        .accessibilityIdentifier(statusIdentifier)
                }
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(rowIdentifier)
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
    OnboardingView(store: .preview)
}
