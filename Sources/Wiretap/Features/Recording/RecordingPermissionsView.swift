import SwiftUI

struct RecordingPermissionsView: View {
    private let placeholders = RecordingPermissionPlaceholder.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Before Recording")
                .font(.headline)

            VStack(alignment: .leading, spacing: 10) {
                ForEach(placeholders) { placeholder in
                    RecordingPermissionRow(placeholder: placeholder)
                }
            }
        }
    }
}

private struct RecordingPermissionRow: View {
    let placeholder: RecordingPermissionPlaceholder

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: placeholder.systemImage)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(placeholder.title)
                        .font(.subheadline.weight(.semibold))

                    Spacer(minLength: 8)

                    Text(placeholder.statusText)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.12)))
                }

                Text(placeholder.copy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
