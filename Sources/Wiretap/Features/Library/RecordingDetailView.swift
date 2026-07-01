import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var store: WiretapStore
    @State private var playbackPosition = 0.34
    @State private var isPlaying = false
    @State private var isConfirmingDelete = false
    @State private var placeholderAction: PlaceholderAction?

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    detailHeader
                    PlayerSurface(
                        recording: recording,
                        isPlaying: $isPlaying,
                        playbackPosition: $playbackPosition
                    )
                    detailSections
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
            }

            Divider()

            RecordingActionBar(
                onReveal: { placeholderAction = .reveal },
                onExport: { placeholderAction = .export },
                onShare: { placeholderAction = .share },
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
        .alert(item: $placeholderAction) { action in
            Alert(
                title: Text(action.title),
                message: Text(action.message),
                dismissButton: .default(Text("OK"))
            )
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
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
                        StatusCapsule(status: recording.status)
                        Label {
                            Text(recording.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                        } icon: {
                            Image(systemName: "calendar")
                        }
                        Label(recording.sourceSummary, systemImage: "waveform")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)

                VStack(alignment: .trailing, spacing: 4) {
                    Text(recording.durationText)
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text(recording.technicalSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var detailSections: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                DetailPanel(title: "File", systemImage: "doc.fill") {
                    MetadataRow(title: "Name", value: recording.fileName)
                    MetadataRow(title: "Location", value: recording.folderPath)
                    MetadataRow(title: "Size", value: recording.fileSizeText)
                }

                DetailPanel(title: "Capture", systemImage: "slider.horizontal.3") {
                    MetadataRow(title: "Sources", value: recording.sourceSummary)
                    MetadataRow(title: "Sample rate", value: "\(recording.sampleRate / 1_000) kHz")
                    MetadataRow(title: "Channels", value: recording.channelCount == 1 ? "Mono" : "Stereo")
                }
            }
        }
    }
}

private struct PlayerSurface: View {
    let recording: Recording
    @Binding var isPlaying: Bool
    @Binding var playbackPosition: Double

    var body: some View {
        VStack(spacing: 18) {
            WaveformPlaceholder(progress: playbackPosition)
                .frame(height: 96)

            HStack(spacing: 14) {
                Button {
                    isPlaying.toggle()
                } label: {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
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
                        Text(recording.durationText)
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
        DurationFormatter.clock.string(from: recording.duration * playbackPosition)
    }
}

private struct WaveformPlaceholder: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<56, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(indexProgress(index) <= progress ? Color.accentColor : Color.secondary.opacity(0.24))
                        .frame(height: barHeight(index, maxHeight: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }

    private func indexProgress(_ index: Int) -> Double {
        Double(index) / 55
    }

    private func barHeight(_ index: Int, maxHeight: CGFloat) -> CGFloat {
        let wave = sin(Double(index) * 0.48) * 0.5 + 0.5
        let secondary = sin(Double(index) * 1.17) * 0.5 + 0.5
        let normalized = 0.22 + (wave * 0.52) + (secondary * 0.22)
        return max(14, maxHeight * normalized)
    }
}

private struct DetailPanel<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(16)
        .frame(minWidth: 300, maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct MetadataRow: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }
}

private struct StatusCapsule: View {
    let status: Recording.Status

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch status {
        case .finalized: .green
        case .recording: .red
        case .interrupted: .orange
        case .missingFile: .secondary
        }
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
        .buttonStyle(.bordered)
        .padding(14)
        .background(.bar)
    }
}

private enum PlaceholderAction: Identifiable {
    case reveal
    case export
    case share

    var id: Self { self }

    var title: String {
        switch self {
        case .reveal: "Reveal in Finder"
        case .export: "Export"
        case .share: "Share"
        }
    }

    var message: String {
        switch self {
        case .reveal:
            "Finder reveal will be connected when real recording files are written to disk."
        case .export:
            "Export will be connected after the recording library has file-backed items."
        case .share:
            "Sharing will be connected after playback and file URLs are wired."
        }
    }
}

#Preview {
    RecordingDetailView(recording: Recording.previewRecordings[0], store: .preview)
        .frame(width: 860, height: 700)
}
