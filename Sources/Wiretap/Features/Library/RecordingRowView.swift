import SwiftUI

struct RecordingRowView: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
            }
            .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title)
                        .font(.headline)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(recording.durationText)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 8) {
                    Text(recording.status.label)
                        .foregroundStyle(statusColor)
                    Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    Text(recording.fileSizeText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier(WiretapAccessibility.Library.recordingRow(id: recording.id))
    }

    private var statusIcon: String {
        switch recording.status {
        case .finalized: "checkmark"
        case .recording: "record.circle.fill"
        case .interrupted: "exclamationmark"
        case .missingFile: "questionmark"
        }
    }

    private var statusColor: Color {
        switch recording.status {
        case .finalized: .green
        case .recording: .red
        case .interrupted: .orange
        case .missingFile: .secondary
        }
    }
}

#Preview {
    List {
        ForEach(Recording.previewRecordings) { recording in
            RecordingRowView(recording: recording)
        }
    }
}
