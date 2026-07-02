import AppKit
import Foundation
import Observation

private enum RecordingFinalizationStrategy {
    case mixSources
    case retainSources

    var diagnosticName: String {
        switch self {
        case .mixSources: "mixSources"
        case .retainSources: "retainSources"
        }
    }
}

private enum RecordingStopReason {
    case userInitiated
    case interrupted(RecordingInterruptionReason)

    var diagnosticName: String {
        switch self {
        case .userInitiated:
            "userInitiated"
        case let .interrupted(reason):
            "interrupted.\(reason.rawValue)"
        }
    }

    var status: Recording.Status {
        switch self {
        case .userInitiated: .finalized
        case .interrupted: .interrupted
        }
    }

    func recordingTitle(createdAt: Date) -> String {
        let timestamp = createdAt.formatted(date: .abbreviated, time: .shortened)

        switch self {
        case .userInitiated:
            return "Recording \(timestamp)"
        case .interrupted:
            return "Interrupted Recording \(timestamp)"
        }
    }

    func sourceSummary(for sources: [RecordingSource]) -> String {
        let summary = Recording.sourceSummary(for: sources)

        switch self {
        case .userInitiated:
            return summary
        case .interrupted:
            return "Interrupted - \(summary)"
        }
    }

    func retainedSourceSummary(didRetainSources: Bool) -> String {
        switch self {
        case .userInitiated:
            return didRetainSources
                ? "Recording sources retained for recovery"
                : "Recording could not be finalized"
        case let .interrupted(reason):
            return didRetainSources
                ? reason.recoverySummary
                : "Interrupted - recording could not be finalized"
        }
    }

    var completionNotice: WiretapNotice? {
        switch self {
        case .userInitiated:
            return nil
        case let .interrupted(reason):
            return WiretapNotice(title: "Recording Interrupted", message: reason.noticeMessage)
        }
    }

    func failureNotice(error: Error?, didRetainSources: Bool) -> WiretapNotice {
        switch self {
        case .userInitiated:
            return WiretapNotice(
                title: "Finalization Failed",
                message: error?.localizedDescription ?? "Wiretap could not finalize this recording."
            )
        case let .interrupted(reason):
            var message = reason.noticeMessage
            message += didRetainSources
                ? " Source files were retained for recovery."
                : " Wiretap could not retain source files for recovery."

            if let error {
                message += " Finalization error: \(error.localizedDescription)"
            }

            return WiretapNotice(title: "Recording Interrupted", message: message)
        }
    }
}

private struct RecordingStartFailure: LocalizedError {
    let notice: WiretapNotice

    var errorDescription: String? {
        notice.message
    }
}

@MainActor
struct RecordingFileActions {
    var reveal: (URL) -> Void
    var chooseExportDestination: (String) -> URL?
    var share: ([URL]) -> Bool

    static let live = RecordingFileActions(
        reveal: { url in
            NSWorkspace.shared.activateFileViewerSelecting([url])
        },
        chooseExportDestination: { fileName in
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Audio]
            panel.nameFieldStringValue = fileName
            panel.canCreateDirectories = true

            guard panel.runModal() == .OK else { return nil }
            return panel.url
        },
        share: { urls in
            guard let contentView = NSApplication.shared.keyWindow?.contentView else {
                return false
            }

            NSSharingServicePicker(items: urls).show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
            return true
        }
    )
}

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
    var systemAudioState: CaptureSourceState = .notChecked
    var microphoneState: CaptureSourceState = .notChecked
    var captureMode: RecordingCaptureMode = .systemAndMicrophone

    @ObservationIgnored private let repository: RecordingLibraryRepository
    @ObservationIgnored private let microphoneRecorder: any MicrophoneRecording
    @ObservationIgnored private let playbackController: any AudioPlaybackControlling
    @ObservationIgnored private let systemAudioTap: any SystemAudioTapping
    @ObservationIgnored private let mixerWriter: AudioMixerWriter
    @ObservationIgnored private let permissionManager: PermissionManager
    @ObservationIgnored private let fileActions: RecordingFileActions
    @ObservationIgnored private let minimumFreeDiskSpaceBytes: Int64
    @ObservationIgnored private let logger = WiretapLog.capture
    @ObservationIgnored private var activeRecordingID: Recording.ID?
    @ObservationIgnored private var activeFinalURL: URL?
    @ObservationIgnored private var activeMicrophoneURL: URL?
    @ObservationIgnored private var activeSystemAudioURL: URL?
    @ObservationIgnored private var activeCaptureSources = Set<RecordingSource>()
    @ObservationIgnored private var activeSourceStartDates: [RecordingSource: Date] = [:]
    @ObservationIgnored private var activeCaptureFrameCounts: [RecordingSource: Int64] = [:]
    @ObservationIgnored private var activeCaptureProgressDates: [RecordingSource: Date] = [:]
    @ObservationIgnored private var activeCaptureFailures: [RecordingSource: Error] = [:]
    @ObservationIgnored private let captureStallThreshold: TimeInterval
    private(set) var pendingPlaybackProgress: [Recording.ID: Double] = [:]

    init(
        recordings: [Recording] = [],
        repository: RecordingLibraryRepository = RecordingLibraryRepository(),
        microphoneRecorder: any MicrophoneRecording = MicrophoneRecorder(),
        playbackController: any AudioPlaybackControlling = AudioPlaybackController(),
        systemAudioTap: any SystemAudioTapping = SystemAudioTap(),
        mixerWriter: AudioMixerWriter = AudioMixerWriter(),
        permissionManager: PermissionManager = PermissionManager(),
        fileActions: RecordingFileActions = .live,
        minimumFreeDiskSpaceBytes: Int64 = 1_000_000_000,
        captureStallThreshold: TimeInterval = 12
    ) {
        self.recordings = recordings
        self.selectedRecordingID = recordings.first?.id
        self.repository = repository
        self.microphoneRecorder = microphoneRecorder
        self.playbackController = playbackController
        self.systemAudioTap = systemAudioTap
        self.mixerWriter = mixerWriter
        self.permissionManager = permissionManager
        self.fileActions = fileActions
        self.minimumFreeDiskSpaceBytes = minimumFreeDiskSpaceBytes
        self.captureStallThreshold = captureStallThreshold
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
        return filteredRecordings.first { $0.id == selectedRecordingID } ?? filteredRecordings.first
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
            return "\(Recording.sourceSummary(for: Array(activeCaptureSources))) capture active"
        }

        if captureMode.requiresMicrophone, permissionState != .ready {
            return "Permissions pending review"
        }

        if captureMode.requiresSystemAudio, systemAudioState == .unavailable {
            return "System audio needs review"
        }

        return "\(captureMode.detailTitle) selected"
    }

    var capturePermissionTitle: String {
        if !captureMode.requiresMicrophone {
            return systemAudioState == .unavailable ? "System Audio Needs Review" : "System Audio Selected"
        }

        if systemAudioState == .unavailable, permissionState == .ready {
            return "System Audio Needs Review"
        }

        return permissionState.title
    }

    var capturePermissionSummary: String {
        if !captureMode.requiresMicrophone {
            return "System audio capture uses macOS Audio Capture permission."
        }

        if systemAudioState == .unavailable, permissionState == .ready {
            return "Microphone access is ready. System audio capture needs Settings review."
        }

        return permissionState.summary
    }

    var canRecord: Bool {
        !captureMode.requiresMicrophone || permissionState != .denied
    }

    var isTimelineActive: Bool {
        isRecording || isPlaying
    }

    func loadLibrary() {
        permissionState = permissionManager.currentState()
        microphoneState = microphoneCaptureState(for: permissionState)
        isOnboardingPresented = permissionState == .notReviewed

        do {
            let loadedRecordings = try repository.loadRecordings()
            let refreshedRecordings = repository.refreshedFileStatuses(for: loadedRecordings)
            recordings = refreshedRecordings
            selectedRecordingID = recordings.first?.id

            if refreshedRecordings != loadedRecordings {
                try repository.saveRecordings(refreshedRecordings)
            }
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
        permissionState = permissionManager.currentState()

        guard canRecord else {
            notice = WiretapNotice(
                title: "Permissions Denied",
                message: permissionState.summary,
                recovery: .microphoneSettings
            )
            return
        }

        var cleanupURLs = [URL]()
        var pendingRecordingID: Recording.ID?

        do {
            try repository.ensureSufficientDiskSpace(minimumBytes: minimumFreeDiskSpaceBytes)

            let id = UUID()
            let startedAt = Date()
            let finalURL = try repository.recordingURL(for: id)
            let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
            let systemAudioURL = try repository.temporarySourceURL(for: id, source: "system")
            let requestedCaptureSources = captureMode.sources
            let requestedCaptureMode = captureMode.rawValue
            var captureSources = Set<RecordingSource>()
            cleanupURLs = [microphoneURL, systemAudioURL]
            pendingRecordingID = id
            logger.info(
                "Starting recording id=\(id.uuidString, privacy: .public) requestedSources=\(WiretapLog.sourceSummary(requestedCaptureSources), privacy: .public) mode=\(requestedCaptureMode, privacy: .public)"
            )
            upsertRecording(
                Recording(
                    id: id,
                    title: "Recording \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                    createdAt: startedAt,
                    duration: 0,
                    fileURL: finalURL,
                    fileSizeBytes: 0,
                    sampleRate: 48_000,
                    channelCount: 2,
                    sourceSummary: Recording.sourceSummary(for: Array(requestedCaptureSources)),
                    status: .recording
                )
            )
            selectedRecordingID = id
            try persistLibrary()

            if requestedCaptureSources.contains(.systemAudio) {
                do {
                    try systemAudioTap.start(writingTo: systemAudioURL)
                    systemAudioState = .ready
                    captureSources.insert(.systemAudio)
                    activeSourceStartDates[.systemAudio] = Date()
                } catch {
                    systemAudioState = .unavailable
                    throw RecordingStartFailure(notice: systemAudioStartFailureNotice(for: error))
                }
            }

            if requestedCaptureSources.contains(.microphone) {
                try microphoneRecorder.startRecording(to: microphoneURL)
                microphoneState = .ready
                captureSources.insert(.microphone)
                activeSourceStartDates[.microphone] = Date()
            }

            activeRecordingID = id
            activeFinalURL = finalURL
            activeMicrophoneURL = microphoneURL
            activeSystemAudioURL = systemAudioURL
            activeCaptureSources = captureSources
            resetCaptureHealthTracking(startedAt: startedAt, sources: captureSources)
            isRecording = true
            recordingStartedAt = startedAt
            elapsedSeconds = 0
            if requestedCaptureSources.contains(.microphone) {
                permissionState = .ready
            }
            upsertRecording(
                Recording(
                    id: id,
                    title: "Recording \(startedAt.formatted(date: .abbreviated, time: .shortened))",
                    createdAt: startedAt,
                    duration: 0,
                    fileURL: finalURL,
                    fileSizeBytes: 0,
                    sampleRate: 48_000,
                    channelCount: 2,
                    sourceSummary: Recording.sourceSummary(for: Array(captureSources)),
                    status: .recording
                )
            )
            selectedRecordingID = id
            saveLibrary()
        } catch {
            if let pendingRecordingID {
                logger.error(
                    "Recording start failed id=\(pendingRecordingID.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
                )
            } else {
                logger.error("Recording start failed before id allocation error=\(error.localizedDescription, privacy: .public)")
            }
            microphoneRecorder.stopRecording()
            systemAudioTap.stop()
            repository.deleteTemporaryFiles(cleanupURLs)
            if let pendingRecordingID {
                recordings.removeAll { $0.id == pendingRecordingID }
                selectedRecordingID = recordings.first?.id
                try? persistLibrary()
            }
            resetRecordingState()
            if let failure = error as? RecordingStartFailure {
                notice = failure.notice
            } else if case RecordingLibraryError.insufficientDiskSpace = error {
                notice = WiretapNotice(title: "Not Enough Disk Space", message: error.localizedDescription)
            } else {
                if captureMode.requiresMicrophone {
                    microphoneState = .unavailable
                } else {
                    systemAudioState = .unavailable
                }
                notice = WiretapNotice(title: "Recording Error", message: error.localizedDescription)
            }
        }
    }

    func stopRecording() {
        finishActiveRecording(reason: .userInitiated, finalization: .mixSources)
    }

    func interruptRecording(reason: RecordingInterruptionReason) {
        finishActiveRecording(reason: .interrupted(reason), finalization: .mixSources)
    }

    func preserveInterruptedRecording(reason: RecordingInterruptionReason) {
        finishActiveRecording(reason: .interrupted(reason), finalization: .retainSources)
    }

    func tick(now: Date = Date()) {
        if isRecording, let recordingStartedAt {
            elapsedSeconds = now.timeIntervalSince(recordingStartedAt)
            updateCaptureHealth(now: now)
        }

        syncPlaybackState()
    }

    func renameSelected(to title: String) {
        guard let selectedRecordingID,
              let index = recordings.firstIndex(where: { $0.id == selectedRecordingID })
        else { return }

        guard recordings[index].status != .recording else { return }

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
            pendingPlaybackProgress[recording.id] = nil
            selectedRecordingID = filteredRecordings.first?.id
            saveLibrary()
        } catch {
            notice = WiretapNotice(title: "Delete Failed", message: error.localizedDescription)
        }
    }

    func reveal(_ recording: Recording) {
        let revealURL = [recording.fileURL, recording.recoveryFolderURL]
            .compactMap(\.self)
            .first { FileManager.default.fileExists(atPath: $0.path) }

        guard let revealURL else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        fileActions.reveal(revealURL)
    }

    func export(_ recording: Recording) {
        guard let fileURL = recording.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        guard let destinationURL = fileActions.chooseExportDestination(recording.fileName) else {
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

        guard fileActions.share([fileURL]) else {
            notice = WiretapNotice(title: "Share Unavailable", message: "Open the library window and try sharing again.")
            return
        }
    }

    func togglePlayback(for recording: Recording) {
        do {
            let requestedProgress = pendingPlaybackProgress[recording.id]
            try playbackController.toggle(recording: recording)
            syncPlaybackState()

            if playbackRecordingID == recording.id, let requestedProgress {
                playbackController.seek(to: requestedProgress)
                pendingPlaybackProgress[recording.id] = nil
                syncPlaybackState()
            }
        } catch {
            notice = WiretapNotice(title: "Playback Failed", message: error.localizedDescription)
        }
    }

    func seekPlayback(for recording: Recording, progress: Double) {
        let clampedProgress = min(1, max(0, progress))

        if playbackRecordingID == recording.id {
            playbackController.seek(to: clampedProgress)
            syncPlaybackState()
        } else {
            pendingPlaybackProgress[recording.id] = clampedProgress
        }
    }

    func playbackProgress(for recording: Recording) -> Double {
        guard playbackRecordingID == recording.id, playbackDuration > 0 else {
            return pendingPlaybackProgress[recording.id] ?? 0
        }

        return min(1, max(0, playbackTime / playbackDuration))
    }

    func playbackTime(for recording: Recording) -> TimeInterval {
        if playbackRecordingID == recording.id {
            return playbackTime
        }

        return recording.duration * (pendingPlaybackProgress[recording.id] ?? 0)
    }

    func stopPlayback() {
        playbackController.stop()
        syncPlaybackState()
    }

    func refreshPermissions() {
        permissionState = permissionManager.currentState()
        microphoneState = microphoneCaptureState(for: permissionState)

        if permissionState == .ready, notice?.recovery == .microphoneSettings {
            notice = nil
        }
    }

    func markPermissionsReviewed() {
        permissionState = .ready
        isOnboardingPresented = false
    }

    func requestPermissions() async {
        permissionState = await permissionManager.requestMicrophoneAccess()
        microphoneState = microphoneCaptureState(for: permissionState)
        isOnboardingPresented = false

        if permissionState == .denied {
            notice = WiretapNotice(
                title: "Microphone Access Denied",
                message: "Open System Settings to allow microphone access before recording.",
                recovery: .microphoneSettings
            )
        }
    }

    func openPermissionSettings() {
        permissionManager.openPrivacySettings(.microphone)
    }

    func openSettings(for recovery: WiretapNoticeRecovery) {
        switch recovery {
        case .microphoneSettings:
            permissionManager.openPrivacySettings(.microphone)
        case .systemAudioSettings:
            permissionManager.openPrivacySettings(.systemAudio)
        }
    }

    func dismissNotice() {
        notice = nil
    }

    func resolveNoticeRecovery(_ recovery: WiretapNoticeRecovery) {
        openSettings(for: recovery)
        dismissNotice()
    }

    private func saveLibrary() {
        do {
            try persistLibrary()
        } catch {
            notice = WiretapNotice(title: "Library Save Failed", message: error.localizedDescription)
        }
    }

    private func persistLibrary() throws {
        try repository.saveRecordings(recordings)
    }

    private func resetRecordingState() {
        isRecording = false
        recordingStartedAt = nil
        elapsedSeconds = 0
        activeRecordingID = nil
        activeFinalURL = nil
        activeMicrophoneURL = nil
        activeSystemAudioURL = nil
        activeCaptureSources = []
        activeSourceStartDates = [:]
        activeCaptureFrameCounts = [:]
        activeCaptureProgressDates = [:]
        activeCaptureFailures = [:]
    }

    private func syncPlaybackState() {
        playbackRecordingID = playbackController.recordingID
        isPlaying = playbackController.isPlaying
        playbackTime = playbackController.currentTime
        playbackDuration = playbackController.duration
    }

    private func upsertRecording(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
    }

    private func resetCaptureHealthTracking(startedAt: Date, sources: Set<RecordingSource>) {
        activeCaptureFrameCounts = [:]
        activeCaptureProgressDates = [:]
        activeCaptureFailures = [:]

        for source in sources {
            let frameCount = captureFrameCount(for: source)
            activeCaptureFrameCounts[source] = frameCount
            if frameCount > 0 {
                activeCaptureProgressDates[source] = startedAt
            }
        }
    }

    private func updateCaptureHealth(now: Date) {
        guard isRecording else { return }

        for source in activeCaptureSources {
            let currentFrameCount = captureFrameCount(for: source)
            let previousFrameCount = activeCaptureFrameCounts[source] ?? 0

            if currentFrameCount > previousFrameCount {
                activeCaptureFrameCounts[source] = currentFrameCount
                activeCaptureProgressDates[source] = now
                activeCaptureFailures[source] = nil
                if source == .systemAudio {
                    systemAudioState = .ready
                } else {
                    microphoneState = .ready
                }
                continue
            }

            guard previousFrameCount > 0,
                  activeCaptureFailures[source] == nil,
                  let lastProgressDate = activeCaptureProgressDates[source],
                  now.timeIntervalSince(lastProgressDate) >= captureStallThreshold
            else { continue }

            let failure = CaptureSourceFailure.stalled(source: source)
            activeCaptureFailures[source] = failure

            if source == .systemAudio {
                systemAudioState = .unavailable
            } else {
                microphoneState = .unavailable
            }

            notice = WiretapNotice(
                title: "Capture Source Stalled",
                message: failure.localizedDescription
            )
        }
    }

    private func captureFrameCount(for source: RecordingSource) -> Int64 {
        switch source {
        case .systemAudio:
            return systemAudioTap.capturedFrameCount
        case .microphone:
            return microphoneRecorder.capturedFrameCount
        }
    }

    private func finishActiveRecording(
        reason: RecordingStopReason,
        finalization: RecordingFinalizationStrategy
    ) {
        guard isRecording else { return }

        let stoppedAt = Date()
        let microphoneResult = microphoneRecorder.stopRecording()
        let systemAudioResult = systemAudioTap.stop()
        let duration = max(elapsedSeconds, microphoneResult.duration, systemAudioResult.duration, 1)
        let title = reason.recordingTitle(createdAt: stoppedAt)
        let captureSources = activeCaptureSources
        let sourceStartDates = activeSourceStartDates
        let captureWriteError = microphoneResult.writeError ?? systemAudioResult.writeError
        let captureHealthError = activeCaptureFailures.values.first
        let capturedSources = capturedSources(
            captureSources: captureSources,
            microphoneResult: microphoneResult,
            systemAudioResult: systemAudioResult
        )
        let missingCaptureSource = missingCaptureSource(
            captureSources: captureSources,
            capturedSources: capturedSources
        )
        let captureDropError = captureDropFailure(
            captureSources: captureSources,
            microphoneResult: microphoneResult,
            systemAudioResult: systemAudioResult
        )

        guard let id = activeRecordingID,
              let finalURL = activeFinalURL,
              let microphoneURL = activeMicrophoneURL,
              let systemAudioURL = activeSystemAudioURL
        else {
            resetRecordingState()
            return
        }
        logger.info(
            "Stopping recording id=\(id.uuidString, privacy: .public) reason=\(reason.diagnosticName, privacy: .public) finalization=\(finalization.diagnosticName, privacy: .public) elapsed=\(duration, privacy: .public) activeSources=\(WiretapLog.sourceSummary(captureSources), privacy: .public) capturedSources=\(WiretapLog.sourceSummary(capturedSources), privacy: .public) micFrames=\(microphoneResult.capturedFrameCount, privacy: .public) systemFrames=\(systemAudioResult.capturedFrameCount, privacy: .public) micDropped=\(microphoneResult.droppedFrameCount, privacy: .public) systemDropped=\(systemAudioResult.droppedFrameCount, privacy: .public)"
        )

        resetRecordingState()

        let cleanupURLs = [systemAudioURL, microphoneURL]
        switch finalization {
        case .mixSources:
            if let captureHealthError {
                retainInterruptedSources(
                    id: id,
                    title: title,
                    durationFallback: duration,
                    cleanupURLs: cleanupURLs,
                    reason: reason,
                    error: captureHealthError
                )
                return
            }

            if let captureWriteError {
                retainInterruptedSources(
                    id: id,
                    title: title,
                    durationFallback: duration,
                    cleanupURLs: cleanupURLs,
                    reason: reason,
                    error: captureWriteError
                )
                return
            }

            if let captureDropError {
                retainInterruptedSources(
                    id: id,
                    title: title,
                    durationFallback: duration,
                    cleanupURLs: cleanupURLs,
                    reason: reason,
                    error: captureDropError
                )
                return
            }

            if capturedSources.isEmpty {
                retainInterruptedSources(
                    id: id,
                    title: title,
                    durationFallback: duration,
                    cleanupURLs: cleanupURLs,
                    reason: reason,
                    error: missingCaptureError(
                        missingSource: missingCaptureSource,
                        expectedSourceCount: captureSources.count
                    )
                )
                return
            }

            let completionNotice = partialCaptureNotice(
                missingSource: missingCaptureSource,
                capturedSources: capturedSources,
                reason: reason
            )

            let inputs = mixerInputs(
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL,
                captureSources: capturedSources,
                sourceStartDates: sourceStartDates,
                duration: duration
            )

            Task {
                await finalizeRecording(
                    id: id,
                    title: title,
                    durationFallback: duration,
                    finalURL: finalURL,
                    inputs: inputs,
                    cleanupURLs: cleanupURLs,
                    reason: reason,
                    completionNotice: completionNotice
                )
            }

        case .retainSources:
            retainInterruptedSources(
                id: id,
                title: title,
                durationFallback: duration,
                cleanupURLs: cleanupURLs,
                reason: reason
            )
        }
    }

    private func missingCaptureSource(
        captureSources: Set<RecordingSource>,
        capturedSources: Set<RecordingSource>
    ) -> RecordingSource? {
        if captureSources.contains(.systemAudio), !capturedSources.contains(.systemAudio) {
            return .systemAudio
        }

        if captureSources.contains(.microphone), !capturedSources.contains(.microphone) {
            return .microphone
        }

        return nil
    }

    private func capturedSources(
        captureSources: Set<RecordingSource>,
        microphoneResult: CaptureStopResult,
        systemAudioResult: CaptureStopResult
    ) -> Set<RecordingSource> {
        var sources = Set<RecordingSource>()

        if captureSources.contains(.systemAudio), systemAudioResult.didCaptureFrames {
            sources.insert(.systemAudio)
        }

        if captureSources.contains(.microphone), microphoneResult.didCaptureFrames {
            sources.insert(.microphone)
        }

        return sources
    }

    private func missingCaptureError(
        missingSource: RecordingSource?,
        expectedSourceCount: Int
    ) -> CaptureSourceFailure {
        guard expectedSourceCount <= 1, let missingSource else {
            return .noCapturedFramesFromAnySource
        }

        return .noCapturedFrames(source: missingSource)
    }

    private func partialCaptureNotice(
        missingSource: RecordingSource?,
        capturedSources: Set<RecordingSource>,
        reason: RecordingStopReason
    ) -> WiretapNotice? {
        guard case .userInitiated = reason,
              let missingSource,
              !capturedSources.isEmpty
        else { return nil }

        switch missingSource {
        case .systemAudio:
            return WiretapNotice(
                title: "System Audio Not Captured",
                message: "Wiretap saved the microphone recording, but no system-audio buffers were captured. Make sure audio is playing and Audio Capture permission is allowed before trying again.",
                recovery: .systemAudioSettings
            )
        case .microphone:
            return WiretapNotice(
                title: "Microphone Not Captured",
                message: "Wiretap saved the system-audio recording, but no microphone buffers were captured. Make sure a default input device is selected and Microphone permission is allowed before trying again.",
                recovery: .microphoneSettings
            )
        }
    }

    private func captureDropFailure(
        captureSources: Set<RecordingSource>,
        microphoneResult: CaptureStopResult,
        systemAudioResult: CaptureStopResult
    ) -> CaptureSourceFailure? {
        if captureSources.contains(.systemAudio), systemAudioResult.droppedFrameCount > 0 {
            return .droppedFrames(source: .systemAudio, count: systemAudioResult.droppedFrameCount)
        }

        if captureSources.contains(.microphone), microphoneResult.droppedFrameCount > 0 {
            return .droppedFrames(source: .microphone, count: microphoneResult.droppedFrameCount)
        }

        return nil
    }

    private func finalizeRecording(
        id: Recording.ID,
        title: String,
        durationFallback: TimeInterval,
        finalURL: URL,
        inputs: [AudioMixerInput],
        cleanupURLs: [URL],
        reason: RecordingStopReason,
        completionNotice: WiretapNotice? = nil
    ) async {
        do {
            logger.info(
                "Finalizing recording id=\(id.uuidString, privacy: .public) inputCount=\(inputs.count, privacy: .public)"
            )
            let mixResult = try await mixerWriter.mix(inputs: inputs, outputURL: finalURL)
            let sourceSummary = reason.sourceSummary(for: mixResult.sources)
            let fileSize = repository.fileSize(for: finalURL)
            let recording = Recording(
                id: id,
                title: title,
                createdAt: Date(),
                duration: max(mixResult.duration, durationFallback, 1),
                fileURL: finalURL,
                fileSizeBytes: fileSize,
                sampleRate: 48_000,
                channelCount: 2,
                sourceSummary: sourceSummary,
                status: reason.status
            )

            upsertRecording(recording)
            selectedRecordingID = recording.id
            saveLibrary()
            repository.deleteTemporaryFiles(cleanupURLs)
            notice = completionNotice ?? reason.completionNotice
            logger.info(
                "Finalized recording id=\(id.uuidString, privacy: .public) duration=\(recording.duration, privacy: .public) fileSize=\(fileSize, privacy: .public) sources=\(WiretapLog.sourceSummary(mixResult.sources), privacy: .public)"
            )
        } catch {
            logger.error(
                "Finalization failed id=\(id.uuidString, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
            retainInterruptedSources(
                id: id,
                title: title,
                durationFallback: durationFallback,
                cleanupURLs: cleanupURLs,
                reason: reason,
                error: error
            )
        }
    }

    private func retainInterruptedSources(
        id: Recording.ID,
        title: String,
        durationFallback: TimeInterval,
        cleanupURLs: [URL],
        reason: RecordingStopReason,
        error: Error? = nil
    ) {
        let recoveryFolderURL = try? repository.retainTemporaryFiles(cleanupURLs, for: id)
        let didRetainSources = recoveryFolderURL != nil
        let interruptedRecording = Recording(
            id: id,
            title: title,
            createdAt: Date(),
            duration: max(durationFallback, 1),
            fileURL: nil,
            recoveryFolderURL: recoveryFolderURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: reason.retainedSourceSummary(didRetainSources: didRetainSources),
            status: .interrupted
        )
        upsertRecording(interruptedRecording)
        selectedRecordingID = interruptedRecording.id
        saveLibrary()
        notice = reason.failureNotice(error: error, didRetainSources: didRetainSources)
        logger.warning(
            "Retained interrupted recording id=\(id.uuidString, privacy: .public) retainedSources=\(didRetainSources, privacy: .public) error=\(error?.localizedDescription ?? "none", privacy: .public)"
        )
    }
}

struct WiretapNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var recovery: WiretapNoticeRecovery? = nil
}

enum WiretapNoticeRecovery: Equatable {
    case microphoneSettings
    case systemAudioSettings

    var buttonTitle: String {
        switch self {
        case .microphoneSettings: "Open Microphone Settings"
        case .systemAudioSettings: "Open Privacy Settings"
        }
    }
}

private enum CaptureSourceFailure: LocalizedError {
    case noCapturedFrames(source: RecordingSource)
    case noCapturedFramesFromAnySource
    case droppedFrames(source: RecordingSource, count: Int64)
    case stalled(source: RecordingSource)

    var errorDescription: String? {
        switch self {
        case let .noCapturedFrames(source):
            "Wiretap did not receive any audio buffers from \(source.label)."
        case .noCapturedFramesFromAnySource:
            "Wiretap did not receive any audio buffers from system audio or the microphone."
        case let .droppedFrames(source, count):
            "Wiretap dropped \(count) audio frames from \(source.label) before finalization completed."
        case let .stalled(source):
            "Wiretap stopped receiving audio buffers from \(source.label). Stop this recording and check the source before trying again."
        }
    }
}

private extension WiretapStore {
    func sourceOffset(
        for source: RecordingSource,
        from sourceStartDates: [RecordingSource: Date],
        referenceDate: Date?
    ) -> TimeInterval {
        guard let sourceStartDate = sourceStartDates[source],
              let referenceDate
        else { return 0 }

        return max(0, sourceStartDate.timeIntervalSince(referenceDate))
    }

    func sourceTargetDuration(
        for source: RecordingSource,
        sessionDuration: TimeInterval,
        sourceStartDates: [RecordingSource: Date],
        referenceDate: Date?
    ) -> TimeInterval? {
        let offset = sourceOffset(
            for: source,
            from: sourceStartDates,
            referenceDate: referenceDate
        )
        let targetDuration = sessionDuration - offset

        return targetDuration > 0 ? targetDuration : nil
    }

    func mixerInputs(
        microphoneURL: URL,
        systemAudioURL: URL,
        captureSources: Set<RecordingSource>,
        sourceStartDates: [RecordingSource: Date],
        duration: TimeInterval
    ) -> [AudioMixerInput] {
        let referenceStartDate = sourceStartDates
            .filter { captureSources.contains($0.key) }
            .map(\.value)
            .min()
        var inputs: [AudioMixerInput] = []

        if captureSources.contains(.systemAudio) {
            inputs.append(
                AudioMixerInput(
                    url: systemAudioURL,
                    source: .systemAudio,
                    startOffset: sourceOffset(
                        for: .systemAudio,
                        from: sourceStartDates,
                        referenceDate: referenceStartDate
                    ),
                    targetDuration: sourceTargetDuration(
                        for: .systemAudio,
                        sessionDuration: duration,
                        sourceStartDates: sourceStartDates,
                        referenceDate: referenceStartDate
                    )
                )
            )
        }

        if captureSources.contains(.microphone) {
            inputs.append(
                AudioMixerInput(
                    url: microphoneURL,
                    source: .microphone,
                    startOffset: sourceOffset(
                        for: .microphone,
                        from: sourceStartDates,
                        referenceDate: referenceStartDate
                    ),
                    targetDuration: sourceTargetDuration(
                        for: .microphone,
                        sessionDuration: duration,
                        sourceStartDates: sourceStartDates,
                        referenceDate: referenceStartDate
                    )
                )
            )
        }

        return inputs
    }

    func microphoneCaptureState(for permissionState: PermissionState) -> CaptureSourceState {
        switch permissionState {
        case .ready:
            return .ready
        case .denied:
            return .unavailable
        case .notReviewed:
            return .notChecked
        }
    }

    func systemAudioStartFailureNotice(for error: Error) -> WiretapNotice {
        if SystemAudioTapError.isPermissionDenied(error) {
            return WiretapNotice(
                title: "System Audio Permission Needed",
                message: "Recording was not started because Wiretap needs Audio Capture permission to include system audio. Open Privacy & Security settings, allow Wiretap under Audio Capture if macOS lists it, then retry recording.",
                recovery: .systemAudioSettings
            )
        }

        return WiretapNotice(
            title: "System Audio Unavailable",
            message: "Recording was not started because the system-audio tap could not be created: \(error.localizedDescription)"
        )
    }
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
