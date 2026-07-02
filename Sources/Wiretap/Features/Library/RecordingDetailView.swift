import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Bindable var store: WiretapStore
    @State private var isConfirmingDelete = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    detailHeader
                    if recording.status != .recording {
                        PlayerSurface(recording: recording, store: store)
                    }
                    detailSections
                }
                .padding(28)
                .frame(maxWidth: 880, alignment: .leading)
            }

            Divider()

            RecordingActionBar(
                canReveal: recording.fileURL != nil || recording.recoveryFolderURL != nil,
                canExport: recording.fileURL != nil
                    && recording.status != .recording
                    && recording.status != .missingFile,
                onReveal: { store.reveal(recording) },
                onExport: { store.export(recording) },
                onShare: { store.share(recording) },
                onDelete: { isConfirmingDelete = true }
            )
        }
        .background(Color(nsColor: .textBackgroundColor))
        .accessibilityIdentifier(WiretapAccessibility.Detail.root)
        .confirmationDialog(
            "Delete Recording?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                store.delete(recording)
            }
            .accessibilityIdentifier(WiretapAccessibility.Detail.deleteConfirmButton)
            Button("Cancel", role: .cancel) {}
                .accessibilityIdentifier(WiretapAccessibility.Detail.deleteCancelButton)
        } message: {
            Text("This removes the library item and its local audio file.")
        }
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 8) {
                    titleView

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
                    Text(displayedDurationText)
                        .font(.title.weight(.semibold))
                        .monospacedDigit()
                    Text(recording.status == .recording ? "Elapsed" : recording.technicalSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var titleView: some View {
        if recording.status == .recording {
            Text(recording.title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .accessibilityIdentifier(WiretapAccessibility.Detail.titleField)
        } else {
            TextField(
                "Recording title",
                text: Binding(
                    get: { recording.title },
                    set: { store.renameSelected(to: $0) }
                )
            )
            .textFieldStyle(.plain)
            .font(.largeTitle.weight(.semibold))
            .accessibilityIdentifier(WiretapAccessibility.Detail.titleField)
        }
    }

    private var displayedDurationText: String {
        recording.status == .recording && store.isRecording ? store.elapsedText : recording.durationText
    }

    private var detailSections: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                DetailPanel(title: "File", systemImage: "doc.fill") {
                    MetadataRow(title: "Name", value: recording.fileName)
                    MetadataRow(title: "Location", value: recording.folderPath)
                    if let recoveryFolderURL = recording.recoveryFolderURL {
                        MetadataRow(title: "Recovery", value: recoveryFolderURL.path)
                    }
                    MetadataRow(title: "Size", value: recording.fileSizeText)
                }

                DetailPanel(title: "Capture", systemImage: "slider.horizontal.3") {
                    MetadataRow(title: "Sources", value: recording.sourceSummary)
                    MetadataRow(title: "Sample rate", value: "\(recording.sampleRate / 1_000) kHz")
                    MetadataRow(title: "Channels", value: recording.channelCount == 1 ? "Mono" : "Stereo")
                }
            }

            if recording.status == .interrupted, let recoveryFolderURL = recording.recoveryFolderURL {
                GridRow {
                    InterruptedRecordingPanel(
                        sourceSummary: recording.sourceSummary,
                        recoveryFolderURL: recoveryFolderURL,
                        canRecord: store.canRecord,
                        onRecord: { store.startRecording() },
                        onReveal: { store.reveal(recording) }
                    )
                    .gridCellColumns(2)
                }
            }
        }
    }
}

private struct PlayerSurface: View {
    let recording: Recording
    @Bindable var store: WiretapStore

    private var progress: Double {
        store.playbackProgress(for: recording)
    }

    private var isCurrentRecording: Bool {
        store.playbackRecordingID == recording.id
    }

    private var isPlayable: Bool {
        recording.status == .finalized && recording.fileURL != nil
    }

    private var progressText: String {
        DurationFormatter.clock.string(from: store.playbackTime(for: recording))
    }

    private var unavailableMessage: String? {
        guard !isPlayable else { return nil }

        switch recording.status {
        case .recording:
            return "Playback is available after the recording is finalized."
        case .interrupted:
            return "This item has retained source files but no finalized .m4a yet."
        case .missingFile:
            return "The finalized audio file is missing from disk."
        case .finalized:
            return "The finalized audio file is unavailable."
        }
    }

    var body: some View {
        VStack(spacing: 18) {
            PlaybackProgressTrack(progress: progress)
                .frame(height: 14)
                .padding(.vertical, 8)

            HStack(spacing: 14) {
                Button {
                    store.togglePlayback(for: recording)
                } label: {
                    Image(systemName: isCurrentRecording && store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .disabled(!isPlayable)
                .help(isCurrentRecording && store.isPlaying ? "Pause" : "Play")
                .accessibilityIdentifier(WiretapAccessibility.Detail.playPauseButton)

                VStack(spacing: 8) {
                    Slider(
                        value: Binding(
                            get: { progress },
                            set: { store.seekPlayback(for: recording, progress: $0) }
                        ),
                        in: 0...1
                    )
                    .accessibilityLabel("Playback position")
                    .disabled(!isPlayable)
                    .accessibilityIdentifier(WiretapAccessibility.Detail.seekSlider)

                    HStack {
                        Text(progressText)
                        Spacer()
                        Text(recording.durationText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            if let unavailableMessage {
                Label(unavailableMessage, systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier(WiretapAccessibility.Detail.playbackUnavailableMessage)
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier(WiretapAccessibility.Detail.player)
    }
}

private struct PlaybackProgressTrack: View {
    let progress: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))

                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor)
                    .frame(width: proxy.size.width * min(1, max(0, progress)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityHidden(true)
    }
}

private struct InterruptedRecordingPanel: View {
    let sourceSummary: String
    let recoveryFolderURL: URL
    let canRecord: Bool
    let onRecord: () -> Void
    let onReveal: () -> Void

    var body: some View {
        DetailPanel(title: "Needs Review", systemImage: "externaldrive.badge.exclamationmark") {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "waveform.badge.exclamationmark")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 10) {
                    Text("This recording was stopped before Wiretap could produce a finalized .m4a.")
                        .font(.callout)
                        .foregroundStyle(.secondary)

                    MetadataRow(title: "Status", value: sourceSummary)
                    MetadataRow(title: "Retained sources", value: recoveryFolderURL.path)

                    HStack(spacing: 10) {
                        Button(action: onReveal) {
                            Label("Reveal Recovery Folder", systemImage: "folder")
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier(WiretapAccessibility.Detail.recoveryRevealButton)

                        Button(action: onRecord) {
                            Label("Record Again", systemImage: "record.circle")
                        }
                        .buttonStyle(.bordered)
                        .disabled(!canRecord)
                        .accessibilityIdentifier(WiretapAccessibility.Detail.recoveryRecordAgainButton)
                    }
                }
            }
        }
        .accessibilityIdentifier(WiretapAccessibility.Detail.recoveryPanel)
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
    let canReveal: Bool
    let canExport: Bool
    let onReveal: () -> Void
    let onExport: () -> Void
    let onShare: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onReveal) {
                Label("Reveal", systemImage: "folder")
            }
            .disabled(!canReveal)
            .accessibilityIdentifier(WiretapAccessibility.Detail.revealButton)

            Button(action: onExport) {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(!canExport)
            .accessibilityIdentifier(WiretapAccessibility.Detail.exportButton)

            Button(action: onShare) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
            .disabled(!canExport)
            .accessibilityIdentifier(WiretapAccessibility.Detail.shareButton)

            Spacer()

            Button(role: .destructive, action: onDelete) {
                Label("Delete", systemImage: "trash")
            }
            .accessibilityIdentifier(WiretapAccessibility.Detail.deleteButton)
        }
        .buttonStyle(.bordered)
        .padding(14)
        .background(.bar)
    }
}

#Preview {
    RecordingDetailView(recording: Recording.previewRecordings[0], store: .preview)
        .frame(width: 860, height: 700)
}
