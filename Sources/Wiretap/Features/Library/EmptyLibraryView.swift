import SwiftUI

struct EmptyLibraryView: View {
    let isFiltering: Bool
    let canRecord: Bool
    let captureMode: RecordingCaptureMode
    let onRecord: () -> Void
    let onReviewPermissions: () -> Void
    let onClearSearch: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(description)
            }

            HStack(spacing: 10) {
                if isFiltering {
                    Button(action: onClearSearch) {
                        Label("Clear Search", systemImage: "xmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier(WiretapAccessibility.Library.emptyClearSearchButton)
                } else {
                    Button(action: onRecord) {
                        Label("Record", systemImage: "record.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!canRecord)
                    .accessibilityIdentifier(WiretapAccessibility.Library.emptyRecordButton)

                    Button(action: onReviewPermissions) {
                        Label("Permissions", systemImage: "lock.shield")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier(WiretapAccessibility.Library.emptyPermissionsButton)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier(WiretapAccessibility.Library.emptyState)
    }

    private var title: String {
        isFiltering ? "No Matches" : "No Recordings"
    }

    private var systemImage: String {
        isFiltering ? "magnifyingglass" : "waveform.circle"
    }

    private var description: String {
        isFiltering
            ? "Try a different search or clear the current filter."
            : captureMode.emptyLibraryDescription
    }
}

#Preview {
    EmptyLibraryView(
        isFiltering: false,
        canRecord: true,
        captureMode: .systemAndMicrophone,
        onRecord: {},
        onReviewPermissions: {},
        onClearSearch: {}
    )
        .frame(width: 420, height: 360)
}
