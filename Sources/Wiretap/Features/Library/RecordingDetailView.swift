import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var store: WiretapStore
    @State private var playbackPosition = 0.34
    @State private var isPlaying = false
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    detailHeader
                    PlayerControlsView(
                        isPlaying: $isPlaying,
                        playbackPosition: $playbackPosition,
                        durationText: recording.durationText
                    )
                    MetadataGrid(recording: recording)
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }

            Divider()

            RecordingActionBar(
                onReveal: {},
                onExport: {},
                onShare: {},
                onDelete: { isConfirmingDelete = true }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .confirmationDialog(
            "Delete Recording?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.deleteSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the library item and its local audio file.")
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField(
                "Recording title",
                text: Binding(
                    get: { recording.title },
                    set: { store.renameSelected(to: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.largeTitle.weight(.semibold))

            HStack(spacing: 12) {
                Label {
                    Text(recording.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                } icon: {
                    Image(systemName: "calendar")
                }
                Label(recording.sourceSummary, systemImage: "waveform")
                Label(recording.technicalSummary, systemImage: "slider.horizontal.3")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

private struct PlayerControlsView: View {
    @Binding var isPlaying: Bool
    @Binding var playbackPosition: Double
    let durationText: String

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help(isPlaying ? "Pause" : "Play")

                VStack(spacing: 8) {
                    Slider(value: $playbackPosition, in: 0...1)
                        .accessibilityLabel("Playback position")

                    HStack {
                        Text(progressText)
                        Spacer()
                        Text(durationText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var progressText: String {
        let seconds = playbackPosition * 60
        return DurationFormatter.clock.string(from: seconds)
    }
}

private struct MetadataGrid: View {
    let recording: Recording

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 14) {
            GridRow {
                MetadataItem(title: "Duration", value: recording.durationText, systemImage: "timer")
                MetadataItem(title: "Size", value: recording.fileSizeText, systemImage: "internaldrive")
            }
            GridRow {
                MetadataItem(title: "Format", value: "AAC .m4a", systemImage: "music.note")
                MetadataItem(title: "Status", value: recording.status.label, systemImage: "checkmark.seal")
            }
        }
    }
}

private struct MetadataItem: View {
    let title: String
    let value: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }
}

private struct RecordingActionBar: View {
    let onReveal: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(14)
    }
}

#Preview {
    RecordingDetailView(recording: Recording.previewRecordings[0], store: .preview)
        .frame(width: 760, height: 620)
}
