import AppKit
import Foundation
import Observation

private enum RecordingFinalizationStrategy {
    case mixSources
    case retainSources
}

private enum RecordingStopReason {
    case userInitiated
    case interrupted(RecordingInterruptionReason)

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

    @ObservationIgnored private let repository: RecordingLibraryRepository
    @ObservationIgnored private let microphoneRecorder: MicrophoneRecorder
    @ObservationIgnored private let playbackController: AudioPlaybackController
    @ObservationIgnored private let systemAudioTap: SystemAudioTap
    @ObservationIgnored private let mixerWriter: AudioMixerWriter
    @ObservationIgnored private let permissionManager: PermissionManager
    @ObservationIgnored private let minimumFreeDiskSpaceBytes: Int64
    @ObservationIgnored private var activeRecordingID: Recording.ID?
    @ObservationIgnored private var activeFinalURL: URL?
    @ObservationIgnored private var activeMicrophoneURL: URL?
    @ObservationIgnored private var activeSystemAudioURL: URL?
    @ObservationIgnored private var activeCaptureSources = Set<RecordingSource>()
    @ObservationIgnored private var activeSourceStartDates: [RecordingSource: Date] = [:]

    init(
        recordings: [Recording] = [],
        repository: RecordingLibraryRepository = RecordingLibraryRepository(),
        microphoneRecorder: MicrophoneRecorder = MicrophoneRecorder(),
        playbackController: AudioPlaybackController = AudioPlaybackController(),
        systemAudioTap: SystemAudioTap = SystemAudioTap(),
        mixerWriter: AudioMixerWriter = AudioMixerWriter(),
        permissionManager: PermissionManager = PermissionManager(),
        minimumFreeDiskSpaceBytes: Int64 = 1_000_000_000
    ) {
        self.recordings = recordings
        self.selectedRecordingID = recordings.first?.id
        self.repository = repository
        self.microphoneRecorder = microphoneRecorder
        self.playbackController = playbackController
        self.systemAudioTap = systemAudioTap
        self.mixerWriter = mixerWriter
        self.permissionManager = permissionManager
        self.minimumFreeDiskSpaceBytes = minimumFreeDiskSpaceBytes
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
            return activeCaptureSources.contains(.systemAudio)
                ? "System audio and default microphone capture active"
                : "Default microphone capture active"
        }

        if permissionState != .ready {
            return "Permissions pending review"
        }

        return systemAudioState == .unavailable
            ? "Microphone ready, system audio needs review"
            : "Permissions ready"
    }

    var capturePermissionTitle: String {
        if systemAudioState == .unavailable, permissionState == .ready {
            return "System Audio Needs Review"
        }

        return permissionState.title
    }

    var capturePermissionSummary: String {
        if systemAudioState == .unavailable, permissionState == .ready {
            return "Microphone access is ready. System audio capture needs Settings review."
        }

        return permissionState.summary
    }

    var canRecord: Bool {
        permissionState != .denied
    }

    func loadLibrary() {
        permissionState = permissionManager.currentState()
        microphoneState = microphoneCaptureState(for: permissionState)

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

        do {
            try repository.ensureSufficientDiskSpace(minimumBytes: minimumFreeDiskSpaceBytes)

            let id = UUID()
            let startedAt = Date()
            let finalURL = try repository.recordingURL(for: id)
            let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
            let systemAudioURL = try repository.temporarySourceURL(for: id, source: "system")
            var captureSources = Set<RecordingSource>()
            cleanupURLs = [microphoneURL, systemAudioURL]

            do {
                try systemAudioTap.start(writingTo: systemAudioURL)
                systemAudioState = .ready
                captureSources.insert(.systemAudio)
                activeSourceStartDates[.systemAudio] = Date()
            } catch {
                systemAudioState = .unavailable
                notice = WiretapNotice(
                    title: SystemAudioTapError.isPermissionDenied(error)
                        ? "System Audio Permission Needed"
                        : "System Audio Unavailable",
                    message: systemAudioFailureMessage(for: error),
                    recovery: SystemAudioTapError.isPermissionDenied(error) ? .systemAudioSettings : nil
                )
            }
            try microphoneRecorder.startRecording(to: microphoneURL)
            microphoneState = .ready
            captureSources.insert(.microphone)
            activeSourceStartDates[.microphone] = Date()

            activeRecordingID = id
            activeFinalURL = finalURL
            activeMicrophoneURL = microphoneURL
            activeSystemAudioURL = systemAudioURL
            activeCaptureSources = captureSources
            isRecording = true
            recordingStartedAt = startedAt
            elapsedSeconds = 0
            permissionState = .ready
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
            microphoneRecorder.stopRecording()
            systemAudioTap.stop()
            microphoneState = .unavailable
            repository.deleteTemporaryFiles(cleanupURLs)
            resetRecordingState()
            notice = WiretapNotice(title: "Recording Error", message: error.localizedDescription)
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
        let revealURL = [recording.fileURL, recording.recoveryFolderURL]
            .compactMap(\.self)
            .first { FileManager.default.fileExists(atPath: $0.path) }

        guard let revealURL else {
            notice = WiretapNotice(title: "Missing File", message: RecordingLibraryError.missingFile.localizedDescription)
            return
        }

        NSWorkspace.shared.activateFileViewerSelecting([revealURL])
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
        activeFinalURL = nil
        activeMicrophoneURL = nil
        activeSystemAudioURL = nil
        activeCaptureSources = []
        activeSourceStartDates = [:]
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

    private func finishActiveRecording(
        reason: RecordingStopReason,
        finalization: RecordingFinalizationStrategy
    ) {
        guard isRecording else { return }

        let stoppedAt = Date()
        let measuredDuration = microphoneRecorder.stopRecording()
        systemAudioTap.stop()
        let duration = max(elapsedSeconds, measuredDuration, 1)
        let title = reason.recordingTitle(createdAt: stoppedAt)
        let captureSources = activeCaptureSources
        let sourceStartDates = activeSourceStartDates

        guard let id = activeRecordingID,
              let finalURL = activeFinalURL,
              let microphoneURL = activeMicrophoneURL,
              let systemAudioURL = activeSystemAudioURL
        else {
            resetRecordingState()
            return
        }

        resetRecordingState()

        let cleanupURLs = [systemAudioURL, microphoneURL]
        switch finalization {
        case .mixSources:
            let inputs = mixerInputs(
                microphoneURL: microphoneURL,
                systemAudioURL: systemAudioURL,
                captureSources: captureSources,
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
                    reason: reason
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

    private func finalizeRecording(
        id: Recording.ID,
        title: String,
        durationFallback: TimeInterval,
        finalURL: URL,
        inputs: [AudioMixerInput],
        cleanupURLs: [URL],
        reason: RecordingStopReason
    ) async {
        do {
            let mixResult = try await mixerWriter.mix(inputs: inputs, outputURL: finalURL)
            let sourceSummary = reason.sourceSummary(for: mixResult.sources)
            let recording = Recording(
                id: id,
                title: title,
                createdAt: Date(),
                duration: max(mixResult.duration, durationFallback, 1),
                fileURL: finalURL,
                fileSizeBytes: repository.fileSize(for: finalURL),
                sampleRate: 48_000,
                channelCount: 2,
                sourceSummary: sourceSummary,
                status: reason.status
            )

            upsertRecording(recording)
            selectedRecordingID = recording.id
            saveLibrary()
            repository.deleteTemporaryFiles(cleanupURLs)
            notice = reason.completionNotice
        } catch {
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
        let referenceStartDate = sourceStartDates.values.min()
        var inputs = [
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
        ]

        if captureSources.contains(.systemAudio) {
            inputs.insert(
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
                ),
                at: 0
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

    func systemAudioFailureMessage(for error: Error) -> String {
        if SystemAudioTapError.isPermissionDenied(error) {
            return "Microphone recording will continue. Open Privacy & Security settings, allow Wiretap under Audio Capture if macOS lists it, then retry recording."
        }

        return "Microphone recording will continue. System-audio tap setup failed: \(error.localizedDescription)"
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
