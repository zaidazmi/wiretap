import Foundation
@testable import Wiretap
import XCTest

final class WiretapStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testLoadLibraryPersistsMissingFileRepair() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let missingURL = try repository.recordingURL(for: UUID())
        let recording = Recording(
            title: "Missing",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 30,
            fileURL: missingURL,
            fileSizeBytes: 2_048,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
        try repository.saveRecordings([recording])

        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        XCTAssertEqual(store.recordings.first?.status, .missingFile)
        XCTAssertEqual(try repository.loadRecordings().first?.status, .missingFile)
    }

    @MainActor
    func testLoadLibraryPersistsRecoveredActiveRecording() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let systemURL = try repository.temporarySourceURL(for: id, source: "system")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        try repository.saveRecordings([
            makeRecording(
                id: id,
                title: "Active",
                fileURL: try repository.recordingURL(for: id),
                status: .recording
            )
        ])

        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        let recoveredRecording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertEqual(recoveredRecording.status, .interrupted)
        XCTAssertEqual(persistedRecording.status, .interrupted)
        XCTAssertNotNil(recoveredRecording.recoveryFolderURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testLoadLibraryPresentsOnboardingWhenPermissionsAreNotReviewed() {
        let store = WiretapStore(
            permissionManager: PermissionManager(currentState: { .notReviewed }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        XCTAssertEqual(store.permissionState, .notReviewed)
        XCTAssertTrue(store.isOnboardingPresented)
    }

    @MainActor
    func testLoadLibraryDoesNotPresentOnboardingWhenPermissionsAreReady() {
        let store = WiretapStore(
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        XCTAssertEqual(store.permissionState, .ready)
        XCTAssertFalse(store.isOnboardingPresented)
    }

    @MainActor
    func testStartRecordingDoesNotFallbackToMicrophoneOnlyWhenSystemAudioPermissionFails() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(startError: SystemAudioTapError.permissionDenied)
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()

        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertEqual(systemAudioTap.startCallCount, 1)
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)
        XCTAssertEqual(store.systemAudioState, .unavailable)
        XCTAssertEqual(store.notice?.title, "System Audio Permission Needed")
        XCTAssertEqual(store.notice?.recovery, .systemAudioSettings)
    }

    @MainActor
    func testStopRecordingRetainsSourcesWhenCaptureWritesFail() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 12,
                writeError: TestCaptureWriteError.failed
            )
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        store.stopRecording()

        let recording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertEqual(persistedRecording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(store.notice?.title, "Finalization Failed")
        XCTAssertEqual(microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(systemAudioTap.stopCallCount, 1)
    }

    @MainActor
    func testStopRecordingRetainsSourcesWhenExpectedCaptureHasNoFrames() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(stopResult: CaptureStopResult(capturedFrameCount: 0))
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 12,
                capturedFrameCount: 48_000
            )
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        store.stopRecording()

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(store.notice?.title, "Finalization Failed")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("System audio") == true)
    }

    @MainActor
    func testTickSynchronizesPlaybackTimeline() {
        let recording = makeRecording(title: "Playback")
        let playbackController = FakePlaybackController()
        playbackController.recordingID = recording.id
        playbackController.isPlaying = true
        playbackController.currentTime = 12
        playbackController.duration = 30
        let store = WiretapStore(
            recordings: [recording],
            playbackController: playbackController,
            minimumFreeDiskSpaceBytes: 0
        )

        store.tick()

        XCTAssertEqual(store.playbackRecordingID, recording.id)
        XCTAssertTrue(store.isPlaying)
        XCTAssertEqual(store.playbackTime, 12)
        XCTAssertEqual(store.playbackDuration, 30)
        XCTAssertEqual(store.playbackProgress(for: recording), 0.4, accuracy: 0.001)
        XCTAssertTrue(store.isTimelineActive)

        playbackController.isPlaying = false
        playbackController.currentTime = 30

        store.tick()

        XCTAssertFalse(store.isPlaying)
        XCTAssertFalse(store.isTimelineActive)
        XCTAssertEqual(store.playbackProgress(for: recording), 1)
    }

    @MainActor
    func testSelectedRecordingFollowsSearchFilter() {
        let designRecording = makeRecording(title: "Design Review")
        let interviewRecording = makeRecording(title: "Customer Interview")
        let store = WiretapStore(
            recordings: [designRecording, interviewRecording],
            minimumFreeDiskSpaceBytes: 0
        )
        store.select(designRecording)

        store.searchText = "Customer"

        XCTAssertEqual(store.filteredRecordings, [interviewRecording])
        XCTAssertEqual(store.selectedRecording, interviewRecording)

        store.searchText = "No Match"

        XCTAssertTrue(store.filteredRecordings.isEmpty)
        XCTAssertNil(store.selectedRecording)
    }

    @MainActor
    func testRenameSelectedPersistsTrimmedTitle() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let recording = makeRecording(title: "Original")
        try repository.saveRecordings([recording])
        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )
        store.loadLibrary()

        store.renameSelected(to: "  Renamed Recording  ")

        XCTAssertEqual(store.recordings.first?.title, "Renamed Recording")
        XCTAssertEqual(try repository.loadRecordings().first?.title, "Renamed Recording")
    }

    @MainActor
    func testRenameSelectedIgnoresActiveRecording() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let recording = makeRecording(title: "Active", status: .recording)
        try repository.saveRecordings([recording])
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )

        store.renameSelected(to: "Too Early")

        XCTAssertEqual(store.recordings.first?.title, "Active")
        XCTAssertEqual(try repository.loadRecordings().first?.title, "Active")
    }

    @MainActor
    func testDeleteSelectedPersistsLibraryAndRemovesFile() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(
            id: id,
            title: "Delete Me",
            fileURL: fileURL,
            fileSizeBytes: repository.fileSize(for: fileURL)
        )
        try repository.saveRecordings([recording])
        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )
        store.loadLibrary()

        store.deleteSelected()

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeRecording(
        id: UUID = UUID(),
        title: String,
        fileURL: URL? = nil,
        fileSizeBytes: Int64 = 0,
        status: Recording.Status = .finalized
    ) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 30,
            fileURL: fileURL,
            fileSizeBytes: fileSizeBytes,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: status
        )
    }
}

private enum TestCaptureWriteError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Synthetic capture write failure"
    }
}

@MainActor
private final class FakePlaybackController: AudioPlaybackControlling {
    var recordingID: Recording.ID?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0

    func toggle(recording: Recording) throws {
        recordingID = recording.id
        isPlaying.toggle()
    }

    func seek(to progress: Double) {
        currentTime = duration * max(0, min(1, progress))
    }

    func stop() {
        recordingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

private final class FakeSystemAudioTap: SystemAudioTapping {
    var isRunning = false
    var startCallCount = 0
    var stopCallCount = 0
    let startError: Error?
    let stopResult: CaptureStopResult

    init(
        startError: Error? = nil,
        stopResult: CaptureStopResult = CaptureStopResult(capturedFrameCount: 48_000)
    ) {
        self.startError = startError
        self.stopResult = stopResult
    }

    func start(writingTo outputURL: URL) throws {
        startCallCount += 1

        if let startError {
            throw startError
        }

        try? Data("system".utf8).write(to: outputURL)
        isRunning = true
    }

    @discardableResult
    func stop() -> CaptureStopResult {
        stopCallCount += 1
        isRunning = false
        return stopResult
    }
}

private final class FakeMicrophoneRecorder: MicrophoneRecording {
    var isRecording = false
    var startCallCount = 0
    var stopCallCount = 0
    var stopResult: CaptureStopResult
    let startError: Error?

    init(
        startError: Error? = nil,
        stopResult: CaptureStopResult = CaptureStopResult(duration: 1, capturedFrameCount: 48_000)
    ) {
        self.startError = startError
        self.stopResult = stopResult
    }

    func startRecording(to url: URL) throws {
        startCallCount += 1

        if let startError {
            throw startError
        }

        try? Data("microphone".utf8).write(to: url)
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        stopCallCount += 1
        isRecording = false
        return stopResult
    }
}
