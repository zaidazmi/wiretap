import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WiretapStore {
    var recordings: [Recording]
    var selectedRecordingID: Recording.ID?
    var searchText = ""
    var isRecording = false
    var recordingStartedAt: Date?
    var elapsedSeconds: TimeInterval = 0
    var permissionState: PermissionState = .notReviewed
    var isOnboardingPresented = false
    var notice: WiretapNotice?
    var playbackRecordingID: Recording.ID?
    var isPlaying = false
    var playbackTime: TimeInterval = 0
    var playbackDuration: TimeInterval = 0

    @ObservationIgnored private let repository: RecordingLibraryRepository
    @ObservationIgnored private let microphoneRecorder: MicrophoneRecorder
    @ObservationIgnored private let playbackController: AudioPlaybackController
    @ObservationIgnored private let systemAudioTap: SystemAudioTap
    @ObservationIgnored private var activeRecordingID: Recording.ID?
    @ObservationIgnored private var activeRecordingURL: URL?

    init(
        recordings: [Recording] = [],
        repository: RecordingLibraryRepository = RecordingLibraryRepository(),
        microphoneRecorder: MicrophoneRecorder = MicrophoneRecorder(),
        playbackController: AudioPlaybackController = AudioPlaybackController(),
        systemAudioTap: SystemAudioTap = SystemAudioTap()
    ) {
        self.recordings = recordings
        self.selectedRecordingID = recordings.first?.id
        self.repository = repository
        self.microphoneRecorder = microphoneRecorder
        self.playbackController = playbackController
        self.systemAudioTap = systemAudioTap
    }

    var filteredRecordings: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }

        return recordings.filter { recording in
            recording.searchableText.localizedStandardContains(query)
        }
    }

    var selectedRecording: Recording? {
        guard let selectedRecordingID else { return filteredRecordings.first }
        return recordings.first { $0.id == selectedRecordingID }
    }

    var elapsedText: String {
        DurationFormatter.clock.string(from: elapsedSeconds)
    }

    var totalDurationText: String {
        DurationFormatter.clock.string(from: recordings.reduce(0) { $0 + $1.duration })
    }

    var totalFileSizeText: String {
        ByteCountFormatter.string(
            fromByteCount: recordings.reduce(Int64(0)) { $0 + $1.fileSizeBytes },
            countStyle: .file
        )
    }

    var lastRecordingText: String {
        guard let createdAt = recordings.map(\.createdAt).max() else {
            return "No recordings yet"
        }

        return createdAt.formatted(date: .abbreviated, time: .shortened)
    }

    var recordingTitle: String {
        isRecording ? "Recording in progress" : "Ready to record"
    }

    var recordingSubtitle: String {
        if isRecording {
            return "Default microphone capture active"
        }

        return permissionState == .ready ? "Permissions ready" : "Permissions pending review"
    }

    var canRecord: Bool {
        permissionState != .denied
    }

    func loadLibrary() {
        do {
            recordings = try repository.loadRecordings()
            selectedRecordingID = recordings.first?.id
        } catch {
            notice = WiretapNotice(title: "Library Error", message: error.localizedDescription)
        }
    }

    func select(_ recording: Recording) {
        selectedRecordingID = recording.id
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard canRecord else {
            notice = WiretapNotice(
                title: "Permissions Denied",
                message: permissionState.summary
            )
            return
        }

        do {
            let id = UUID()
            let url = try repository.recordingURL(for: id)
            do {
                try systemAudioTap.start()
            } catch {
                notice = WiretapNotice(
                    title: "System Audio Pending",
                    message: "Microphone recording will continue. System-audio tap setup failed: \(error.localizedDescription)"
                )
            }
            try microphoneRecorder.startRecording(to: url)

            activeRecordingID = id
            activeRecordingURL = url
            isRecording = true
            recordingStartedAt = Date()
            elapsedSeconds = 0
            permissionState = .ready
        } catch {
            notice = WiretapNotice(title: "Recording Error", message: error.localizedDescription)
        }
    }

    func stopRecording() {
        guard isRecording else { return }

        let measuredDuration = microphoneRecorder.stopRecording()
        systemAudioTap.stop()
        let duration = max(elapsedSeconds, measuredDuration, 1)
        let title = "Recording \(Date().formatted(date: .abbreviated, time: .shortened))"

        guard let id = activeRecordingID,
              let fileURL = activeRecordingURL
        else {
            resetRecordingState()
            return
        }

        var status: Recording.Status = .finalized
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            status = .missingFile
        }

        let recording = Recording(
            id: id,
            title: title,
            createdAt: Date(),
            duration: duration,
            fileURL: fileURL,
            fileSizeBytes: repository.fileSize(for: fileURL),
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Default microphone",
            status: status
        )

        recordings.insert(recording, at: 0)
        selectedRecordingID = recording.id
        saveLibrary()
        resetRecordingState()
    }

    func tick(now: Date = Date()) {
        if isRecording, let recordingStartedAt {
            elapsedSeconds = now.timeIntervalSince(recordingStartedAt)
        }

        syncPlaybackState()
    }

    func renameSelected(to title: String) {
        guard let selectedRecordingID,
              let index = recordings.firstIndex(where: { $0.id == selectedRecordingID })
        else { return }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }

        recordings[index].title = trimmedTitle
        saveLibrary()
    }

    func deleteSelected() {
        guard let selectedRecordingID,
              let recording = recordings.first(where: { $0.id == selectedRecordingID })
        else { return }

        delete(recording)
    }

    func delete(_ recording: Recording) {
        do {
            if playbackRecordingID == recording.id {
                stopPlayback()
            }

            try repository.deleteFileIfPresent(for: recording)
            recordings.removeAll { $0.id == recording.id }
            selectedRecordingID = filteredRecordings.first?.id
            saveLibrary()
        } catch {
            notice = WiretapNotice(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    func reveal(_ recording: Recording) {
        guard let fileURL = recording.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
    }

    func export(_ recording: Recording) {
        guard recording.fileURL != nil else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Audio]
        panel.nameFieldStringValue = recording.fileName
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }

        do {
            try repository.copyRecording(recording, to: destinationURL)
        } catch {
            notice = WiretapNotice(title: "Export Failed", message: error.localizedDescription)
        }
    }

    func share(_ recording: Recording) {
        guard let fileURL = recording.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        guard let contentView = NSApplication.shared.keyWindow?.contentView else {
            notice = WiretapNotice(title: "Share Unavailable", message: "Open the library window and try sharing again.")
            return
        }

        NSSharingServicePicker(items: [fileURL]).show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }

    func togglePlayback(for recording: Recording) {
        do {
            try playbackController.toggle(recording: recording)
            syncPlaybackState()
        } catch {
            notice = WiretapNotice(title: "Playback Failed", message: error.localizedDescription)
        }
    }

    func seekPlayback(for recording: Recording, progress: Double) {
        guard playbackRecordingID == recording.id else { return }
        playbackController.seek(to: progress)
        syncPlaybackState()
    }

    func playbackProgress(for recording: Recording) -> Double {
        guard playbackRecordingID == recording.id, playbackDuration > 0 else {
            return 0
        }

        return min(1, max(0, playbackTime / playbackDuration))
    }

    func stopPlayback() {
        playbackController.stop()
        syncPlaybackState()
    }

    func markPermissionsReviewed() {
        permissionState = .ready
        isOnboardingPresented = false
    }

    private func saveLibrary() {
        do {
            try repository.saveRecordings(recordings)
        } catch {
            notice = WiretapNotice(title: "Library Save Failed", message: error.localizedDescription)
        }
    }

    private func resetRecordingState() {
        isRecording = false
        recordingStartedAt = nil
        elapsedSeconds = 0
        activeRecordingID = nil
        activeRecordingURL = nil
    }

    private func syncPlaybackState() {
        playbackRecordingID = playbackController.recordingID
        isPlaying = playbackController.isPlaying
        playbackTime = playbackController.currentTime
        playbackDuration = playbackController.duration
    }
}

struct WiretapNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
}

extension WiretapStore {
    static func live() -> WiretapStore {
        let store = WiretapStore()
        store.loadLibrary()
        return store
    }

    static var preview: WiretapStore {
        WiretapStore(recordings: Recording.previewRecordings)
    }
}
