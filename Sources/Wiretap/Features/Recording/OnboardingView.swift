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
                    systemImage: "speaker.wave.3.fill"
                )
                PermissionRow(
                    title: "Microphone",
                    summary: "Uses the current macOS default input device.",
                    systemImage: "mic.fill"
                )
                PermissionRow(
                    title: "Local Files",
                    summary: "Saves mixed AAC .m4a recordings in the app library.",
                    systemImage: "externaldrive.fill"
                )
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.permissionState.title)
                        .font(.headline)
                    Text(store.permissionState.summary)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button("Not Now") {
                    dismiss()
                }

                Button("Continue") {
                    store.markPermissionsReviewed()
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 560)
    }
}

private struct PermissionRow: View {
    let title: String
    let summary: String
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.tint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(summary)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    OnboardingView(store: .preview)
}
