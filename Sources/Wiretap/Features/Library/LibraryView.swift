import SwiftUI

struct LibraryView: View {
    @Bindable var store: WiretapStore

    var body: some View {
        VStack(spacing: 0) {
            LibraryStatusStrip(store: store)

            Divider()

            NavigationSplitView {
                RecordingSidebar(store: store)
                    .navigationSplitViewColumnWidth(min: 320, ideal: 360, max: 440)
            } detail: {
                if let recording = store.selectedRecording {
                    RecordingDetailView(recording: recording, store: store)
                } else {
                    EmptyLibraryView(
                        isFiltering: !store.searchText.isEmpty,
                        canRecord: store.canRecord,
                        onRecord: { store.startRecording() },
                        onReviewPermissions: { store.isOnboardingPresented = true },
                        onClearSearch: { store.searchText = "" }
                    )
                }
            }
        }
        .accessibilityIdentifier(WiretapAccessibility.Library.window)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    store.isOnboardingPresented = true
                } label: {
                    Label("Permissions", systemImage: "lock.shield")
                }
                .help("Review capture permissions")
                .accessibilityIdentifier(WiretapAccessibility.Library.toolbarPermissionsButton)

                RecordingControlView(store: store, style: .toolbar)
            }
        }
    }
}

private struct LibraryStatusStrip: View {
    let store: WiretapStore

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 10) {
                RecordingStatusBadge(isRecording: store.isRecording)
                    .font(.title3)

                VStack(alignment: .leading, spacing: 2) {
                    Text(store.recordingTitle)
                        .font(.headline)
                    Text(store.recordingSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            LibraryMetric(title: "Elapsed", value: store.isRecording ? store.elapsedText : "00:00")
            LibraryMetric(title: "Recordings", value: "\(store.recordings.count)")
            LibraryMetric(title: "Duration", value: store.totalDurationText)
            LibraryMetric(title: "Size", value: store.totalFileSizeText)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
        .accessibilityIdentifier(WiretapAccessibility.Library.statusStrip)
    }
}

private struct LibraryMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(minWidth: 76, alignment: .trailing)
    }
}

private struct RecordingSidebar: View {
    @Bindable var store: WiretapStore

    var body: some View {
        VStack(spacing: 0) {
            LibraryHeader(store: store)

            if store.filteredRecordings.isEmpty {
                SidebarEmptyState(isFiltering: !store.searchText.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $store.selectedRecordingID) {
                    Section("Recordings") {
                        ForEach(store.filteredRecordings) { recording in
                            RecordingRowView(recording: recording)
                                .tag(recording.id)
                        }
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 70)
                .accessibilityIdentifier(WiretapAccessibility.Library.recordingList)
            }
        }
        .searchable(text: $store.searchText, prompt: "Search recordings")
        .accessibilityIdentifier(WiretapAccessibility.Library.sidebar)
    }
}

private struct LibraryHeader: View {
    let store: WiretapStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(.tint)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Wiretap")
                        .font(.title2.weight(.semibold))
                    Text("Local audio library")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                SidebarStat(title: "Last", value: store.lastRecordingText)
                SidebarStat(title: "Stored", value: store.totalFileSizeText)
            }
        }
        .padding(18)
    }
}

private struct SidebarEmptyState: View {
    let isFiltering: Bool

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: isFiltering ? "magnifyingglass" : "tray")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(isFiltering ? "No Matches" : "No Recordings")
                .font(.callout.weight(.semibold))

            Text(isFiltering ? "Use the main empty state to clear the search." : "New recordings will appear here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 220)
        }
        .padding(24)
    }
}

private struct SidebarStat: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

#Preview {
    LibraryView(store: .preview)
        .frame(width: 1180, height: 760)
}
