import SwiftUI

struct RecordingDetailView: View {
    let recording: Recording
    @Binding var playbackState: RecordingPlaybackState
    let actions: RecordingFileActions

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    detailHeader

                    PlayerControlsView(
                        recording: recording,
                        playbackState: $playbackState
                    )

                    MetadataGrid(recording: recording)
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
            }

            Divider()

            RecordingActionBar(actions: actions)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var detailHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(recording.title)
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 12) {
                Label {
                    Text(recording.createdAt, format: .dateTime.weekday().month().day().hour().minute())
                } icon: {
                    Image(systemName: "calendar")
                }
                Label(recording.sourceSummary, systemImage: "mic")
                Label(recording.technicalSummary, systemImage: "slider.horizontal.3")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }
}

private struct PlayerControlsView: View {
    let recording: Recording
    @Binding var playbackState: RecordingPlaybackState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button {
                    playbackState.currentTime = max(0, playbackState.currentTime - 15)
                } label: {
                    Image(systemName: "gobackward.15")
                        .frame(width: 24, height: 24)
                }
                .help("Skip back 15 seconds")

                Button {
                    playbackState.isPlaying.toggle()
                } label: {
                    Image(systemName: playbackState.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .frame(width: 42, height: 42)
                }
                .buttonStyle(.borderedProminent)
                .clipShape(Circle())
                .help(playbackState.isPlaying ? "Pause" : "Play")

                Button {
                    playbackState.currentTime = min(recording.duration, playbackState.currentTime + 15)
                } label: {
                    Image(systemName: "goforward.15")
                        .frame(width: 24, height: 24)
                }
                .help("Skip forward 15 seconds")

                VStack(spacing: 8) {
                    Slider(value: currentTime, in: 0...max(recording.duration, 1))
                        .accessibilityLabel("Playback position")

                    HStack {
                        Text(DurationFormatter.clock.string(from: playbackState.currentTime))
                        Spacer()
                        Text(recording.durationText)
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 22) {
                HStack(spacing: 8) {
                    Image(systemName: "speaker.wave.2")
                        .foregroundStyle(.secondary)

                    Slider(value: $playbackState.volume, in: 0...1)
                        .frame(maxWidth: 180)
                        .accessibilityLabel("Playback volume")
                }

                Picker("Speed", selection: $playbackState.speed) {
                    ForEach(RecordingPlaybackSpeed.allCases) { speed in
                        Text(speed.title).tag(speed)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)

                Spacer()
            }
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var currentTime: Binding<Double> {
        Binding(
            get: { min(playbackState.currentTime, recording.duration) },
            set: { playbackState.currentTime = min(max(0, $0), recording.duration) }
        )
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
            GridRow {
                MetadataItem(title: "Source", value: recording.sourceSummary, systemImage: "mic")
                MetadataItem(title: "Location", value: recording.folderPath, systemImage: "folder")
            }
        }
        .textSelection(.enabled)
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
                    .lineLimit(2)
            }
        }
        .frame(minWidth: 220, alignment: .leading)
    }
}

private struct RecordingActionBar: View {
    let actions: RecordingFileActions

    var body: some View {
        HStack(spacing: 10) {
            Button(action: actions.rename) {
                Label("Rename", systemImage: "pencil")
            }
            Button(action: actions.reveal) {
                Label("Reveal", systemImage: "folder")
            }
            Button(action: actions.export) {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            Button(action: actions.share) {
                Label("Share", systemImage: "square.and.arrow.up")
            }

            Spacer()

            Button(role: .destructive, action: actions.delete) {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding(14)
    }
}

#Preview {
    @Previewable @State var playbackState = RecordingPlaybackState()

    RecordingDetailView(
        recording: Recording.previewRecordings[0],
        playbackState: $playbackState,
        actions: RecordingFileActions(
            rename: {},
            reveal: {},
            export: {},
            share: {},
            delete: {}
        )
    )
    .frame(width: 760, height: 620)
}
