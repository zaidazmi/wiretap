import Foundation
import SwiftUI

@MainActor
struct RecordingLibraryView: View {
    @State private var recordings: [Recording]
    @State private var selectedRecordingID: Recording.ID?
    @State private var searchText: String
    @State private var playbackState = RecordingPlaybackState()
    @State private var renameRequest: RecordingRenameRequest?
    @State private var recordingToDelete: Recording?
    @State private var notice: RecordingLibraryNotice?

    init(recordings: [Recording] = Recording.previewRecordings, initialSearchText: String = "") {
        let visibleRecordings = Self.filtered(recordings: recordings, query: initialSearchText)

        _recordings = State(initialValue: recordings)
        _selectedRecordingID = State(initialValue: visibleRecordings.first?.id)
        _searchText = State(initialValue: initialSearchText)
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationTitle("Library")
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            detail
        }
        .searchable(text: $searchText, prompt: Text("Search recordings"))
        .sheet(item: $renameRequest) { request in
            RenameRecordingSheet(request: request) { newTitle in
                renameRecording(id: request.id, title: newTitle)
            }
        }
        .alert("Delete Recording?", isPresented: deleteAlertBinding, presenting: recordingToDelete) { recording in
            Button("Delete", role: .destructive) {
                delete(recording)
            }
            Button("Cancel", role: .cancel) {
                recordingToDelete = nil
            }
        } message: { recording in
            Text("This removes \"\(recording.title)\" from the sample library. File deletion will be connected with the storage layer later.")
        }
        .overlay(alignment: .bottom) {
            if let notice {
                RecordingNoticeBanner(message: notice.message)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .task(id: notice?.id) {
            guard notice != nil else {
                return
            }

            try? await Task.sleep(for: .seconds(2))

            withAnimation(.easeOut(duration: 0.2)) {
                notice = nil
            }
        }
        .onChange(of: filteredRecordings.map(\.id)) { _, visibleIDs in
            reconcileSelection(visibleIDs: visibleIDs)
        }
        .onChange(of: selectedRecordingID) { _, _ in
            playbackState = RecordingPlaybackState()
        }
    }

    private var sidebar: some View {
        Group {
            if recordings.isEmpty {
                EmptyLibraryView(isFiltering: false)
            } else if filteredRecordings.isEmpty {
                EmptyLibraryView(isFiltering: true)
            } else {
                List(selection: $selectedRecordingID) {
                    ForEach(filteredRecordings) { recording in
                        RecordingRowView(recording: recording)
                            .tag(recording.id)
                            .contextMenu {
                                recordingActionMenuItems(for: recording)
                            }
                    }
                }
                .listStyle(.sidebar)
                .environment(\.defaultMinListRowHeight, 58)
            }
        }
    }

    private var detail: some View {
        Group {
            if recordings.isEmpty {
                ContentUnavailableView(
                    "Ready for a Library",
                    systemImage: "tray",
                    description: Text("The UI is prepared for recordings, search, playback controls, and file actions.")
                )
            } else if filteredRecordings.isEmpty {
                ContentUnavailableView(
                    "No Matching Recording",
                    systemImage: "magnifyingglass",
                    description: Text("Adjust the search field to return to the sample library.")
                )
            } else if let selectedRecording {
                RecordingDetailView(
                    recording: selectedRecording,
                    playbackState: $playbackState,
                    actions: actions(for: selectedRecording)
                )
            } else {
                ContentUnavailableView(
                    "Select a Recording",
                    systemImage: "sidebar.left",
                    description: Text("Choose a recording from the library to view details and player controls.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var selectedRecording: Recording? {
        recordings.first { $0.id == selectedRecordingID }
    }

    private var filteredRecordings: [Recording] {
        Self.filtered(recordings: recordings, query: searchText)
    }

    private var deleteAlertBinding: Binding<Bool> {
        Binding(
            get: { recordingToDelete != nil },
            set: { isPresented in
                if !isPresented {
                    recordingToDelete = nil
                }
            }
        )
    }

    private static func filtered(recordings: [Recording], query: String) -> [Recording] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedQuery.isEmpty else {
            return recordings.sorted { $0.createdAt > $1.createdAt }
        }

        return recordings
            .filter { $0.searchableText.localizedStandardContains(trimmedQuery) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    private func reconcileSelection(visibleIDs: [Recording.ID]) {
        guard !visibleIDs.isEmpty else {
            selectedRecordingID = nil
            return
        }

        if let selectedRecordingID, visibleIDs.contains(selectedRecordingID) {
            return
        }

        selectedRecordingID = visibleIDs.first
    }

    private func actions(for recording: Recording) -> RecordingFileActions {
        RecordingFileActions(
            rename: { renameRequest = RecordingRenameRequest(id: recording.id, currentTitle: recording.title) },
            reveal: { showPlaceholder("Reveal in Finder", recording: recording) },
            export: { showPlaceholder("Export Copy", recording: recording) },
            share: { showPlaceholder("Share", recording: recording) },
            delete: { recordingToDelete = recording }
        )
    }

    @ViewBuilder
    private func recordingActionMenuItems(for recording: Recording) -> some View {
        let actions = actions(for: recording)

        Button {
            actions.rename()
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            actions.reveal()
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }

        Button {
            actions.export()
        } label: {
            Label("Export Copy...", systemImage: "square.and.arrow.down")
        }

        Button {
            actions.share()
        } label: {
            Label("Share...", systemImage: "square.and.arrow.up")
        }

        Divider()

        Button(role: .destructive) {
            actions.delete()
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func renameRecording(id: Recording.ID, title: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanTitle.isEmpty,
              let index = recordings.firstIndex(where: { $0.id == id })
        else {
            return
        }

        recordings[index].title = cleanTitle
        showNotice("Renamed to \"\(cleanTitle)\"")
    }

    private func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }

        if selectedRecordingID == recording.id {
            selectedRecordingID = filteredRecordings.first?.id
        }

        playbackState = RecordingPlaybackState()
        recordingToDelete = nil
        showNotice("Removed \"\(recording.title)\" from the sample library")
    }

    private func showPlaceholder(_ action: String, recording: Recording) {
        showNotice("\(action) placeholder for \"\(recording.title)\"")
    }

    private func showNotice(_ message: String) {
        withAnimation(.spring(duration: 0.25)) {
            notice = RecordingLibraryNotice(message: message)
        }
    }
}

struct RecordingFileActions {
    var rename: () -> Void
    var reveal: () -> Void
    var export: () -> Void
    var share: () -> Void
    var delete: () -> Void
}

struct RecordingPlaybackState: Equatable {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var volume = 0.8
    var speed = RecordingPlaybackSpeed.normal
}

enum RecordingPlaybackSpeed: String, CaseIterable, Identifiable {
    case slow
    case normal
    case fast
    case faster

    var id: Self { self }

    var title: String {
        switch self {
        case .slow:
            "0.75x"
        case .normal:
            "1x"
        case .fast:
            "1.25x"
        case .faster:
            "1.5x"
        }
    }
}

private struct RecordingRenameRequest: Identifiable {
    let id: Recording.ID
    let currentTitle: String
}

private struct RecordingLibraryNotice: Identifiable {
    var id = UUID()
    var message: String
}

private struct RenameRecordingSheet: View {
    let request: RecordingRenameRequest
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var title: String

    init(request: RecordingRenameRequest, onSave: @escaping (String) -> Void) {
        self.request = request
        self.onSave = onSave
        _title = State(initialValue: request.currentTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Rename Recording")
                .font(.title2.weight(.semibold))

            TextField("Recording name", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)

            HStack {
                Spacer()

                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private func save() {
        onSave(title)
        dismiss()
    }
}

private struct RecordingNoticeBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(.separator.opacity(0.45))
            }
            .shadow(radius: 10, y: 4)
    }
}

#Preview("Library") {
    RecordingLibraryView()
        .frame(width: 1_100, height: 720)
}

#Preview("Empty") {
    RecordingLibraryView(recordings: [])
        .frame(width: 1_100, height: 720)
}

#Preview("No Search Results") {
    RecordingLibraryView(initialSearchText: "transcript")
        .frame(width: 1_100, height: 720)
}
