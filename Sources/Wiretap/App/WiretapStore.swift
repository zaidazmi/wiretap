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

    init(recordings: [Recording] = []) {
        self.recordings = recordings
        self.selectedRecordingID = recordings.first?.id
    }

    var filteredRecordings: [Recording] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return recordings }

        return recordings.filter { recording in
            recording.title.localizedStandardContains(query)
                || recording.sourceSummary.localizedStandardContains(query)
                || recording.createdAt.formatted(date: .abbreviated, time: .shortened).localizedStandardContains(query)
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
            return "System output + default microphone"
        }

        return permissionState == .ready ? "Permissions ready" : "Permissions pending review"
    }

    var canRecord: Bool {
        permissionState != .denied
    }

    func select(_ recording: Recording) {
        selectedRecordingID = recording.id
    }

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        guard canRecord else { return }
        isRecording = true
        recordingStartedAt = Date()
        elapsedSeconds = 0
    }

    func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        let duration = max(elapsedSeconds, 18)
        let recording = Recording(
            title: "Recording \(Date().formatted(date: .abbreviated, time: .shortened))",
            createdAt: Date(),
            duration: duration,
            fileSizeBytes: Int64(duration * 16_000),
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System output + default microphone",
            status: .finalized
        )
        recordings.insert(recording, at: 0)
        selectedRecordingID = recording.id
        recordingStartedAt = nil
        elapsedSeconds = 0
    }

    func tick(now: Date = Date()) {
        guard isRecording, let recordingStartedAt else { return }
        elapsedSeconds = now.timeIntervalSince(recordingStartedAt)
    }

    func renameSelected(to title: String) {
        guard let selectedRecordingID,
              let index = recordings.firstIndex(where: { $0.id == selectedRecordingID })
        else { return }
        recordings[index].title = title
    }

    func deleteSelected() {
        guard let selectedRecordingID,
              let index = recordings.firstIndex(where: { $0.id == selectedRecordingID })
        else { return }
        recordings.remove(at: index)
        self.selectedRecordingID = filteredRecordings.first?.id
    }

    func markPermissionsReviewed() {
        permissionState = .ready
        isOnboardingPresented = false
    }
}

extension WiretapStore {
    static var preview: WiretapStore {
        WiretapStore(recordings: Recording.previewRecordings)
    }
}
