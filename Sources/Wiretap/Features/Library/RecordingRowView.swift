import SwiftUI

struct RecordingRowView: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                StatusPill(status: recording.status)

                Text(recording.createdAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)

                Text(recording.fileSizeText)
                    .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
    }
}

private struct StatusPill: View {
    let status: Recording.Status

    var body: some View {
        Label(status.label, systemImage: statusIcon)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(statusColor)
    }

    private var statusIcon: String {
        switch status {
        case .finalized: "checkmark.circle.fill"
        case .recording: "record.circle.fill"
        case .interrupted: "exclamationmark.triangle.fill"
        case .missingFile: "questionmark.folder.fill"
        }
    }

    private var statusColor: Color {
        switch status {
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
