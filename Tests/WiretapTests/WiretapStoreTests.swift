import AVFoundation
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
    func testMicrophonePermissionDenialKeepsOnboardingPresented() async {
        let microphoneRequest = MutablePermissionRequest(result: .denied)
        let store = WiretapStore(
            permissionManager: PermissionManager(
                currentState: { .notReviewed },
                requestMicrophoneAccess: { await microphoneRequest.request() }
            ),
            minimumFreeDiskSpaceBytes: 0
        )
        store.isOnboardingPresented = true

        let shouldDismiss = await store.requestPermissions()

        XCTAssertEqual(microphoneRequest.callCount, 1)
        XCTAssertFalse(shouldDismiss)
        XCTAssertTrue(store.isOnboardingPresented)
        XCTAssertEqual(store.onboardingRecovery, .microphoneSettings)
        XCTAssertEqual(store.notice?.recovery, .microphoneSettings)
    }

    @MainActor
    func testSystemAudioRecoveryKeepsOnboardingPresentedWhenRequired() async {
        let microphoneRequest = MutablePermissionRequest(result: .ready)
        let store = WiretapStore(
            permissionManager: PermissionManager(
                currentState: { .ready },
                requestMicrophoneAccess: { await microphoneRequest.request() }
            ),
            minimumFreeDiskSpaceBytes: 0
        )
        store.systemAudioState = .unavailable
        store.isOnboardingPresented = true

        let shouldDismiss = await store.requestPermissions()

        XCTAssertEqual(microphoneRequest.callCount, 1)
        XCTAssertFalse(shouldDismiss)
        XCTAssertTrue(store.isOnboardingPresented)
        XCTAssertEqual(store.onboardingRecovery, .systemAudioSettings)
    }

    @MainActor
    func testReadyMicrophoneSummaryDoesNotClaimSystemAudioAlreadyAvailable() {
        let store = WiretapStore(
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )
        store.permissionState = .ready
        store.systemAudioState = .notChecked

        XCTAssertEqual(
            store.capturePermissionSummary,
            "Microphone access is ready. macOS checks Screen & System Audio Recording permission when recording starts."
        )
    }

    @MainActor
    func testRecordAgainStartsSystemAndMicrophoneRecording() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let interruptedID = UUID()
        let recoveryFolderURL = try makeRecoveryFolder(
            for: interruptedID,
            sources: [.systemAudio],
            repository: repository
        )
        let interruptedRecording = makeRecording(
            id: interruptedID,
            title: "Interrupted",
            recoveryFolderURL: recoveryFolderURL,
            status: .interrupted,
            sourceSummary: RecordingInterruptionReason.systemSleep.recoverySummary
        )
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            recordings: [interruptedRecording],
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        XCTAssertTrue(store.canRetryRecording(interruptedRecording))

        store.recordAgain(interruptedRecording)
        try await waitForRecordingStart(store)

        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(systemAudioTap.startCallCount, 1)
        XCTAssertEqual(microphoneRecorder.startCallCount, 1)
    }

    @MainActor
    func testRecordAgainBlocksWhenMicrophoneDenied() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let interruptedID = UUID()
        let recoveryFolderURL = try makeRecoveryFolder(
            for: interruptedID,
            sources: [.microphone],
            repository: repository
        )
        let interruptedRecording = makeRecording(
            id: interruptedID,
            title: "Interrupted",
            recoveryFolderURL: recoveryFolderURL,
            status: .interrupted,
            sourceSummary: RecordingInterruptionReason.appTermination.recoverySummary
        )
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            recordings: [interruptedRecording],
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .denied }),
            minimumFreeDiskSpaceBytes: 0
        )
        store.permissionState = .denied

        XCTAssertFalse(store.canRetryRecording(interruptedRecording))

        store.recordAgain(interruptedRecording)
        try await waitForRecordingStart(store)

        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(systemAudioTap.startCallCount, 0)
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)
        XCTAssertEqual(store.notice?.recovery, .microphoneSettings)
    }

    @MainActor
    func testRecordAgainCannotReplaceAnActiveRecordingSession() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let interruptedRecording = makeRecording(
            title: "Interrupted",
            status: .interrupted,
            sourceSummary: RecordingInterruptionReason.systemSleep.recoverySummary
        )
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            recordings: [interruptedRecording],
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        let activeRecordingID = try XCTUnwrap(
            store.recordings.first(where: { $0.status == .recording })?.id
        )

        XCTAssertFalse(store.canRecord)
        XCTAssertFalse(store.canRetryRecording(interruptedRecording))

        store.recordAgain(interruptedRecording)
        await Task.yield()

        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(
            store.recordings.first(where: { $0.status == .recording })?.id,
            activeRecordingID
        )
        XCTAssertEqual(store.recordings.filter { $0.status == .recording }.count, 1)
        XCTAssertEqual(systemAudioTap.startCallCount, 1)
        XCTAssertEqual(microphoneRecorder.startCallCount, 1)

        store.preserveInterruptedRecording(reason: .appTermination)
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
    func testStartRecordingWaitsForConfirmedSystemAudioStartup() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(startDelay: .milliseconds(100))
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        let requestedAt = Date()
        store.startRecording()

        XCTAssertTrue(store.isStartingRecording)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(store.recordingTitle, "Starting recording")
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)

        try await waitForRecordingStart(store)

        XCTAssertFalse(store.isStartingRecording)
        XCTAssertTrue(store.isRecording)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(store.recordingStartedAt).timeIntervalSince(requestedAt),
            0.08
        )
        XCTAssertEqual(systemAudioTap.startCallCount, 1)
        XCTAssertEqual(microphoneRecorder.startCallCount, 1)
    }

    @MainActor
    func testStartRecordingStopsWiretapPlaybackBeforeCapture() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let playbackController = FakePlaybackController()
        playbackController.recordingID = UUID()
        playbackController.isPlaying = true
        playbackController.duration = 30
        playbackController.currentTime = 12
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: FakeMicrophoneRecorder(),
            playbackController: playbackController,
            systemAudioTap: FakeSystemAudioTap(),
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )
        store.tick()
        XCTAssertTrue(store.isPlaying)

        store.startRecording()
        try await waitForRecordingStart(store)

        XCTAssertTrue(store.isRecording)
        XCTAssertFalse(store.isPlaying)
        XCTAssertNil(playbackController.recordingID)
        XCTAssertFalse(playbackController.isPlaying)

        store.preserveInterruptedRecording(reason: .appTermination)
    }

    @MainActor
    func testPlaybackCannotStartDuringActiveRecording() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let playbackController = FakePlaybackController()
        let playableRecording = makeRecording(title: "Previous Recording")
        let store = WiretapStore(
            recordings: [playableRecording],
            repository: repository,
            microphoneRecorder: FakeMicrophoneRecorder(),
            playbackController: playbackController,
            systemAudioTap: FakeSystemAudioTap(),
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        store.togglePlayback(for: playableRecording)
        store.seekPlayback(for: playableRecording, progress: 0.5)

        XCTAssertTrue(store.isRecording)
        XCTAssertNil(playbackController.recordingID)
        XCTAssertFalse(playbackController.isPlaying)
        XCTAssertNil(store.pendingPlaybackProgress[playableRecording.id])

        store.preserveInterruptedRecording(reason: .appTermination)
    }

    @MainActor
    func testToggleRecordingCancelsPendingSystemAudioStartup() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(startDelay: .seconds(1))
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        XCTAssertTrue(store.isStartingRecording)

        store.toggleRecording()
        try await waitForRecordingStart(store)

        XCTAssertFalse(store.isStartingRecording)
        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)
        XCTAssertGreaterThanOrEqual(systemAudioTap.stopCallCount, 1)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testRuntimeSystemAudioFailureStopsAndRetainsActiveSources() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        let originalCreatedAt = try XCTUnwrap(store.recordings.first?.createdAt)

        systemAudioTap.triggerRuntimeFailure(SystemAudioTapError.displayUnavailable)

        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(store.systemAudioState, .unavailable)
        let interrupted = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(interrupted.createdAt, originalCreatedAt)
        XCTAssertNotNil(interrupted.recoveryFolderURL)
        XCTAssertTrue(
            try XCTUnwrap(store.notice?.message)
                .localizedStandardContains("System audio capture stopped")
        )
        XCTAssertGreaterThanOrEqual(systemAudioTap.stopCallCount, 1)
        XCTAssertGreaterThanOrEqual(microphoneRecorder.stopCallCount, 1)
    }

    @MainActor
    func testStartRecordingDoesNotFallbackToMicrophoneOnlyWhenSystemAudioPermissionFails() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(
            startError: SystemAudioTapError.permissionDenied,
            startDelay: .milliseconds(50)
        )
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)

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
    func testStartRecordingReportsLowDiskSpaceWithoutChangingCaptureStates() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: Int64.max
        )
        store.microphoneState = .ready
        store.systemAudioState = .ready

        store.startRecording()
        try await waitForRecordingStart(store)

        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)
        XCTAssertEqual(systemAudioTap.startCallCount, 0)
        XCTAssertEqual(store.microphoneState, .ready)
        XCTAssertEqual(store.systemAudioState, .ready)
        XCTAssertEqual(store.notice?.title, "Not Enough Disk Space")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("safe recording session") == true)
    }

    @MainActor
    func testTickStopsAndRetainsSourcesBeforeDiskSpaceRunsOut() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        var availableBytes: Int64 = 2_000_000_000
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 1_000_000_000,
            availableDiskSpace: { availableBytes }
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        XCTAssertTrue(store.isRecording)

        availableBytes = 500_000_000
        store.tick(now: Date().addingTimeInterval(1))

        XCTAssertFalse(store.isRecording)
        let interrupted = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertNotNil(interrupted.recoveryFolderURL)
        XCTAssertTrue(
            try XCTUnwrap(store.notice?.message)
                .localizedStandardContains("disk filled up")
        )
    }

    @MainActor
    func testStartRecordingBlocksLoopbackMicrophoneForSystemAndMicrophoneMode() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            microphoneRouteInspector: MicrophoneRouteInspector {
                MicrophoneRouteInspection(deviceName: "BlackHole 2ch")
            },
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)

        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertEqual(systemAudioTap.startCallCount, 0)
        XCTAssertEqual(microphoneRecorder.startCallCount, 0)
        XCTAssertEqual(store.notice?.title, "Choose a Microphone Input")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("avoid doubled playback") == true)
        XCTAssertEqual(store.notice?.recovery, .microphoneSettings)
    }

    @MainActor
    func testStopRecordingFinalizesMixedOutputAndCleansTemporarySources() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(
            stopResult: CaptureStopResult(duration: 0.16, capturedFrameCount: 7_680),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.16, frequency: 440)
            }
        )
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(duration: 0.16, capturedFrameCount: 7_680),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.16, frequency: 660)
            }
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)

        let activeRecording = try XCTUnwrap(store.recordings.first)
        let finalURL = try XCTUnwrap(activeRecording.fileURL)
        let microphoneURL = try repository.temporarySourceURL(for: activeRecording.id, source: "microphone")
        let systemAudioURL = try repository.temporarySourceURL(for: activeRecording.id, source: "system")
        XCTAssertTrue(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: systemAudioURL.path))

        store.stopRecording()

        XCTAssertFalse(store.isRecording)
        XCTAssertTrue(store.isProcessingRecording)
        XCTAssertFalse(store.canRecord)
        XCTAssertEqual(store.recordings.first?.status, .processing)
        XCTAssertEqual(store.recordingTitle, "Saving recording")

        try await waitUntil("recording finalizes") {
            store.recordings.first?.status == .finalized
        }

        let recording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .finalized)
        XCTAssertEqual(persistedRecording.status, .finalized)
        XCTAssertEqual(recording.id, activeRecording.id)
        XCTAssertEqual(recording.fileURL, finalURL)
        XCTAssertNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.sourceSummary, "System audio + default microphone")
        XCTAssertGreaterThan(recording.duration, 0.12)
        XCTAssertGreaterThan(recording.fileSizeBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertNil(store.notice)
        XCTAssertFalse(store.isProcessingRecording)
        XCTAssertTrue(store.canRecord)
    }

    @MainActor
    func testPlaybackRateSelectionIsForwardedToController() {
        let playbackController = FakePlaybackController()
        let store = WiretapStore(
            playbackController: playbackController,
            minimumFreeDiskSpaceBytes: 0
        )

        store.setPlaybackRate(.onePointTwentyFour)

        XCTAssertEqual(store.playbackRate, .onePointTwentyFour)
        XCTAssertEqual(playbackController.playbackRate, .onePointTwentyFour)
    }

    @MainActor
    func testStopRecordingRetainsSourcesWhenCaptureWritesFail() async throws {
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
        try await waitForRecordingStart(store)
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
    func testStopRecordingSurfacesDroppedCaptureFramesAsFinalizationFailure() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let droppedFrameError = AudioBufferListFileWriterError.bufferPoolExhausted(frameCount: 12_000)
        let systemAudioTap = FakeSystemAudioTap()
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 12,
                capturedFrameCount: 48_000,
                droppedFrameCount: 12_000,
                writeError: droppedFrameError
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
        try await waitForRecordingStart(store)
        store.stopRecording()

        let recording = try XCTUnwrap(store.recordings.first)
        let recoveryFolderURL = try XCTUnwrap(recording.recoveryFolderURL)
        let retainedFileNames = try Set(FileManager.default.contentsOfDirectory(atPath: recoveryFolderURL.path))
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertEqual(retainedFileNames.count, 2)
        XCTAssertEqual(store.notice?.title, "Finalization Failed")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("dropped 12000 audio frames") == true)
        XCTAssertTrue(store.notice?.message.localizedStandardContains("buffer pool was exhausted") == true)
    }

    @MainActor
    func testStopRecordingRetainsSourcesWhenCaptureReportsDroppedFramesWithoutWriteError() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(
            stopResult: CaptureStopResult(
                capturedFrameCount: 48_000,
                droppedFrameCount: 12_000
            )
        )
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
        try await waitForRecordingStart(store)
        store.stopRecording()

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(store.notice?.title, "Finalization Failed")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("dropped 12000 audio frames") == true)
        XCTAssertTrue(store.notice?.message.localizedStandardContains("System audio") == true)
    }

    @MainActor
    func testStopRecordingFinalizesMicrophoneOnlyWhenSystemAudioHasNoFrames() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(stopResult: CaptureStopResult(capturedFrameCount: 0))
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 0.16,
                capturedFrameCount: 7_680
            ),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.16, frequency: 660)
            }
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)

        let activeRecording = try XCTUnwrap(store.recordings.first)
        let finalURL = try XCTUnwrap(activeRecording.fileURL)
        let microphoneURL = try repository.temporarySourceURL(for: activeRecording.id, source: "microphone")
        let systemAudioURL = try repository.temporarySourceURL(for: activeRecording.id, source: "system")

        store.stopRecording()

        try await waitUntil("microphone-only recording finalizes") {
            store.recordings.first?.status == .finalized
        }

        let recording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .finalized)
        XCTAssertEqual(persistedRecording.status, .finalized)
        XCTAssertEqual(recording.fileURL, finalURL)
        XCTAssertNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.sourceSummary, "default microphone")
        XCTAssertEqual(persistedRecording.sourceSummary, "default microphone")
        XCTAssertGreaterThan(recording.duration, 0.12)
        XCTAssertGreaterThan(recording.fileSizeBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertEqual(store.notice?.title, "System Audio Not Captured")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("no system-audio buffers") == true)
        XCTAssertEqual(store.notice?.recovery, .systemAudioSettings)
    }

    @MainActor
    func testStopRecordingFinalizesSystemAudioOnlyWhenMicrophoneHasNoFrames() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(
            stopResult: CaptureStopResult(duration: 0.16, capturedFrameCount: 7_680),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.16, frequency: 440)
            }
        )
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 0,
                capturedFrameCount: 0
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
        try await waitForRecordingStart(store)

        let activeRecording = try XCTUnwrap(store.recordings.first)
        let finalURL = try XCTUnwrap(activeRecording.fileURL)
        let microphoneURL = try repository.temporarySourceURL(for: activeRecording.id, source: "microphone")
        let systemAudioURL = try repository.temporarySourceURL(for: activeRecording.id, source: "system")

        store.stopRecording()

        try await waitUntil("system-audio-only recording finalizes") {
            store.recordings.first?.status == .finalized
        }

        let recording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .finalized)
        XCTAssertEqual(persistedRecording.status, .finalized)
        XCTAssertEqual(recording.fileURL, finalURL)
        XCTAssertNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.sourceSummary, "System audio")
        XCTAssertEqual(persistedRecording.sourceSummary, "System audio")
        XCTAssertGreaterThan(recording.duration, 0.12)
        XCTAssertGreaterThan(recording.fileSizeBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemAudioURL.path))
        XCTAssertEqual(store.notice?.title, "Microphone Not Captured")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("no microphone buffers") == true)
        XCTAssertEqual(store.notice?.recovery, .microphoneSettings)
    }

    @MainActor
    func testStopRecordingRetainsSourcesWhenNoExpectedCaptureHasFrames() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(stopResult: CaptureStopResult(capturedFrameCount: 0))
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(capturedFrameCount: 0)
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        store.stopRecording()

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(store.notice?.title, "Finalization Failed")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("system audio or the microphone") == true)
    }

    @MainActor
    func testTickIgnoresSilentSystemAudioButWarnsForStalledMicrophone() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let systemAudioTap = FakeSystemAudioTap(
            stopResult: CaptureStopResult(capturedFrameCount: 48_000),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.2, frequency: 440)
            }
        )
        let microphoneRecorder = FakeMicrophoneRecorder(
            stopResult: CaptureStopResult(
                duration: 20,
                capturedFrameCount: 96_000
            ),
            startWriter: { [weak self] url in
                try self?.writeTone(to: url, duration: 0.2, frequency: 660)
            }
        )
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0,
            captureStallThreshold: 5
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        let startedAt = try XCTUnwrap(store.recordingStartedAt)
        systemAudioTap.capturedFrameCount = 48_000
        microphoneRecorder.capturedFrameCount = 48_000

        store.tick(now: startedAt.addingTimeInterval(1))

        microphoneRecorder.capturedFrameCount = 96_000

        store.tick(now: startedAt.addingTimeInterval(8))

        XCTAssertEqual(store.systemAudioState, .ready)
        XCTAssertEqual(store.microphoneState, .ready)
        XCTAssertNil(store.notice)

        store.tick(now: startedAt.addingTimeInterval(14))

        XCTAssertEqual(store.systemAudioState, .ready)
        XCTAssertEqual(store.microphoneState, .unavailable)
        XCTAssertEqual(store.notice?.title, "Capture Source Stalled")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("microphone") == true)

        store.stopRecording()

        try await waitUntil("stalled-source recording finalizes") {
            store.recordings.first?.status == .finalized
        }

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertEqual(recording.status, .finalized)
        XCTAssertNotNil(recording.fileURL)
        XCTAssertNil(recording.recoveryFolderURL)
        XCTAssertEqual(store.systemAudioState, .ready)
        XCTAssertNil(store.notice)
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
    func testSeekBeforePlaybackStartsIsAppliedWhenPlaybackBegins() {
        let recording = makeRecording(title: "Preseek")
        let playbackController = FakePlaybackController()
        playbackController.duration = recording.duration
        let store = WiretapStore(
            recordings: [recording],
            playbackController: playbackController,
            minimumFreeDiskSpaceBytes: 0
        )

        store.seekPlayback(for: recording, progress: 0.5)

        XCTAssertEqual(store.playbackProgress(for: recording), 0.5, accuracy: 0.001)
        XCTAssertEqual(store.playbackTime(for: recording), 15, accuracy: 0.001)

        store.togglePlayback(for: recording)

        XCTAssertEqual(store.playbackRecordingID, recording.id)
        XCTAssertEqual(store.playbackTime, 15, accuracy: 0.001)
        XCTAssertEqual(store.playbackProgress(for: recording), 0.5, accuracy: 0.001)
        XCTAssertNil(store.pendingPlaybackProgress[recording.id])
    }

    @MainActor
    func testPrePlaybackSeekDoesNotReapplyAfterPauseResume() {
        let recording = makeRecording(title: "Resume")
        let playbackController = FakePlaybackController()
        playbackController.duration = recording.duration
        let store = WiretapStore(
            recordings: [recording],
            playbackController: playbackController,
            minimumFreeDiskSpaceBytes: 0
        )

        store.seekPlayback(for: recording, progress: 0.5)
        store.togglePlayback(for: recording)
        store.seekPlayback(for: recording, progress: 0.75)

        XCTAssertEqual(store.playbackTime, 22.5, accuracy: 0.001)

        store.togglePlayback(for: recording)
        playbackController.currentTime = 23
        store.togglePlayback(for: recording)

        XCTAssertEqual(store.playbackTime, 23, accuracy: 0.001)
    }

    @MainActor
    func testRefreshPermissionsSynchronizesMicrophoneState() {
        let permissionState = MutablePermissionState(.denied)
        let store = WiretapStore(
            permissionManager: PermissionManager(currentState: { permissionState.value }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.refreshPermissions()

        XCTAssertEqual(store.permissionState, .denied)
        XCTAssertEqual(store.microphoneState, .unavailable)

        permissionState.value = .ready
        store.notice = WiretapNotice(
            title: "Microphone Access Denied",
            message: "Open System Settings to allow microphone access before recording.",
            recovery: .microphoneSettings
        )

        store.refreshPermissions()

        XCTAssertEqual(store.permissionState, .ready)
        XCTAssertEqual(store.microphoneState, .ready)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testDismissNoticeClearsCurrentNotice() {
        let store = WiretapStore(minimumFreeDiskSpaceBytes: 0)
        store.notice = WiretapNotice(title: "Playback Failed", message: "Could not start playback.")

        store.dismissNotice()

        XCTAssertNil(store.notice)
    }

    @MainActor
    func testResolveNoticeRecoveryOpensSettingsAndClearsNotice() {
        let openedTarget = MutablePrivacySettingsTarget()
        let store = WiretapStore(
            permissionManager: PermissionManager(openPrivacySettings: { target in
                openedTarget.value = target
            }),
            minimumFreeDiskSpaceBytes: 0
        )
        store.notice = WiretapNotice(
            title: "System Audio Needs Review",
            message: "Open Privacy Settings.",
            recovery: .systemAudioSettings
        )

        store.resolveNoticeRecovery(.systemAudioSettings)

        XCTAssertEqual(openedTarget.value, .systemAudio)
        XCTAssertNil(store.notice)
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
    func testRevealSelectsExistingRecordingFile() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(id: id, title: "Reveal", fileURL: fileURL)
        var revealedURL: URL?
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(reveal: { revealedURL = $0 }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.reveal(recording)

        XCTAssertEqual(revealedURL, fileURL)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testRevealSelectsRecoveryFolderForInterruptedRecording() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let recoveryURL = try repository.recoveryURL(for: id)
        try FileManager.default.createDirectory(at: recoveryURL, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: recoveryURL.appendingPathComponent("source.m4a"))
        let recording = makeRecording(
            id: id,
            title: "Recovery",
            recoveryFolderURL: recoveryURL,
            status: .interrupted
        )
        var revealedURL: URL?
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(reveal: { revealedURL = $0 }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.reveal(recording)

        XCTAssertEqual(revealedURL, recoveryURL)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testRevealReportsMissingFileWhenManagedFileIsGone() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let missingURL = try repository.recordingURL(for: UUID())
        let recording = makeRecording(title: "Missing", fileURL: missingURL)
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(reveal: { _ in XCTFail("Reveal should not run for missing files") }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.reveal(recording)

        XCTAssertEqual(store.notice?.title, "Missing File")
    }

    @MainActor
    func testExportCopiesRecordingToChosenDestination() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        let sourceData = Data("audio".utf8)
        try sourceData.write(to: fileURL)
        let destinationURL = temporaryDirectory.appendingPathComponent("Exported.m4a")
        let recording = makeRecording(id: id, title: "Export", fileURL: fileURL)
        var requestedFileName: String?
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(
                chooseExportDestination: { fileName in
                    requestedFileName = fileName
                    return destinationURL
                }
            ),
            minimumFreeDiskSpaceBytes: 0
        )

        store.export(recording)

        XCTAssertEqual(requestedFileName, recording.fileName)
        XCTAssertEqual(try Data(contentsOf: destinationURL), sourceData)
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testExportReportsMissingFileBeforeChoosingDestination() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let missingURL = try repository.recordingURL(for: UUID())
        let recording = makeRecording(title: "Missing Export", fileURL: missingURL)
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(
                chooseExportDestination: { _ in
                    XCTFail("Export should not request a destination for missing files")
                    return nil
                }
            ),
            minimumFreeDiskSpaceBytes: 0
        )

        store.export(recording)

        XCTAssertEqual(store.notice?.title, "Missing File")
    }

    @MainActor
    func testSharePresentsExistingRecordingFile() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(id: id, title: "Share", fileURL: fileURL)
        var sharedURLs = [URL]()
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(share: { urls in
                sharedURLs = urls
                return true
            }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.share(recording)

        XCTAssertEqual(sharedURLs, [fileURL])
        XCTAssertNil(store.notice)
    }

    @MainActor
    func testShareReportsUnavailableWhenPresenterCannotOpen() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(id: id, title: "Share", fileURL: fileURL)
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(share: { _ in false }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.share(recording)

        XCTAssertEqual(store.notice?.title, "Share Unavailable")
    }

    @MainActor
    func testShareReportsMissingFileBeforePresentingPicker() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let missingURL = try repository.recordingURL(for: UUID())
        let recording = makeRecording(title: "Missing Share", fileURL: missingURL)
        let store = WiretapStore(
            recordings: [recording],
            repository: repository,
            fileActions: makeFileActions(share: { _ in
                XCTFail("Share should not run for missing files")
                return true
            }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.share(recording)

        XCTAssertEqual(store.notice?.title, "Missing File")
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

    @MainActor
    func testDeleteIgnoresActiveRecording() async throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: FakeMicrophoneRecorder(),
            systemAudioTap: FakeSystemAudioTap(),
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )

        store.startRecording()
        try await waitForRecordingStart(store)
        let activeRecording = try XCTUnwrap(store.recordings.first)

        store.delete(activeRecording)

        XCTAssertTrue(store.isRecording)
        XCTAssertEqual(store.recordings.first?.id, activeRecording.id)
        XCTAssertEqual(try repository.loadRecordings().first?.id, activeRecording.id)

        store.preserveInterruptedRecording(reason: .appTermination)
    }

    private func makeRecording(
        id: UUID = UUID(),
        title: String,
        fileURL: URL? = nil,
        recoveryFolderURL: URL? = nil,
        fileSizeBytes: Int64 = 0,
        status: Recording.Status = .finalized,
        sourceSummary: String = "System audio + default microphone"
    ) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 30,
            fileURL: fileURL,
            recoveryFolderURL: recoveryFolderURL,
            fileSizeBytes: fileSizeBytes,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: sourceSummary,
            status: status
        )
    }

    private func makeRecoveryFolder(
        for id: Recording.ID,
        sources: Set<RecordingSource>,
        repository: RecordingLibraryRepository
    ) throws -> URL {
        let recoveryFolderURL = try repository.recoveryURL(for: id)
        try FileManager.default.createDirectory(
            at: recoveryFolderURL,
            withIntermediateDirectories: true
        )

        for source in sources {
            let fileSuffix = source == .systemAudio ? "system" : "microphone"
            let fileURL = recoveryFolderURL.appendingPathComponent("\(id.uuidString)-\(fileSuffix).m4a")
            try Data("source".utf8).write(to: fileURL)
        }

        return recoveryFolderURL
    }

    @MainActor
    private func waitForRecordingStart(_ store: WiretapStore) async throws {
        try await waitUntil("recording start completes") {
            !store.isStartingRecording
        }
    }

    @MainActor
    private func waitUntil(
        _ description: String,
        timeout: TimeInterval = 2,
        condition: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                XCTFail("Timed out waiting for \(description)")
                return
            }

            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func writeTone(
        to url: URL,
        duration: TimeInterval,
        frequency: Double,
        amplitude: Double = 0.2
    ) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(48_000 * duration)
            ),
            let channels = buffer.floatChannelData
        else {
            XCTFail("Could not create test audio buffer")
            return
        }

        buffer.frameLength = buffer.frameCapacity
        for frame in 0..<Int(buffer.frameLength) {
            let sample = Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000) * amplitude)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }

        let settings: [String: Any]
        if url.pathExtension.lowercased() == "caf" {
            var pcmSettings = format.settings
            pcmSettings[AVFormatIDKey] = Int(kAudioFormatLinearPCM)
            pcmSettings[AVSampleRateKey] = 48_000
            pcmSettings[AVNumberOfChannelsKey] = 2
            pcmSettings[AVLinearPCMIsNonInterleaved] = false
            settings = pcmSettings
        } else {
            settings = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    @MainActor
    private func makeFileActions(
        reveal: @escaping (URL) -> Void = { _ in },
        chooseExportDestination: @escaping (String) -> URL? = { _ in nil },
        share: @escaping ([URL]) -> Bool = { _ in false }
    ) -> RecordingFileActions {
        RecordingFileActions(
            reveal: reveal,
            chooseExportDestination: chooseExportDestination,
            share: share
        )
    }
}

private enum TestCaptureWriteError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Synthetic capture write failure"
    }
}

private final class MutablePermissionState: @unchecked Sendable {
    var value: PermissionState

    init(_ value: PermissionState) {
        self.value = value
    }
}

private final class MutablePermissionRequest: @unchecked Sendable {
    private(set) var callCount = 0
    var result: PermissionState

    init(result: PermissionState) {
        self.result = result
    }

    func request() async -> PermissionState {
        callCount += 1
        return result
    }
}

private final class MutablePrivacySettingsTarget: @unchecked Sendable {
    var value: PrivacySettingsTarget?
}

@MainActor
private final class FakePlaybackController: AudioPlaybackControlling {
    var recordingID: Recording.ID?
    var isPlaying = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var playbackRate: PlaybackRate = .normal

    func toggle(recording: Recording) throws {
        recordingID = recording.id
        isPlaying.toggle()
    }

    func seek(to progress: Double) {
        currentTime = duration * max(0, min(1, progress))
    }

    func setPlaybackRate(_ rate: PlaybackRate) {
        playbackRate = rate
    }

    func stop() {
        recordingID = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }
}

private final class FakeSystemAudioTap: SystemAudioTapping, @unchecked Sendable {
    var isRunning = false
    var capturedFrameCount: Int64 = 0
    var startCallCount = 0
    var stopCallCount = 0
    var prewarmCallCount = 0
    let startError: Error?
    let startDelay: Duration?
    let stopResult: CaptureStopResult
    let startWriter: ((URL) throws -> Void)?
    var runtimeFailureHandler: SystemAudioFailureHandler?

    func prewarm() {
        prewarmCallCount += 1
    }

    func setRuntimeFailureHandler(_ handler: @escaping SystemAudioFailureHandler) {
        runtimeFailureHandler = handler
    }

    @MainActor
    func triggerRuntimeFailure(_ error: Error) {
        isRunning = false
        runtimeFailureHandler?(error)
    }

    init(
        startError: Error? = nil,
        startDelay: Duration? = nil,
        stopResult: CaptureStopResult = CaptureStopResult(capturedFrameCount: 48_000),
        startWriter: ((URL) throws -> Void)? = nil
    ) {
        self.startError = startError
        self.startDelay = startDelay
        self.stopResult = stopResult
        self.startWriter = startWriter
    }

    func start(writingTo outputURL: URL) async throws {
        startCallCount += 1

        if let startDelay {
            try await Task.sleep(for: startDelay)
        }

        if let startError {
            throw startError
        }

        if let startWriter {
            try startWriter(outputURL)
        } else {
            try? Data("system".utf8).write(to: outputURL)
        }
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
    var capturedFrameCount: Int64 = 0
    var startCallCount = 0
    var stopCallCount = 0
    var stopResult: CaptureStopResult
    let startError: Error?
    let startWriter: ((URL) throws -> Void)?

    init(
        startError: Error? = nil,
        stopResult: CaptureStopResult = CaptureStopResult(duration: 1, capturedFrameCount: 48_000),
        startWriter: ((URL) throws -> Void)? = nil
    ) {
        self.startError = startError
        self.stopResult = stopResult
        self.startWriter = startWriter
    }

    func startRecording(to url: URL) throws {
        startCallCount += 1

        if let startError {
            throw startError
        }

        if let startWriter {
            try startWriter(url)
        } else {
            try? Data("microphone".utf8).write(to: url)
        }
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        stopCallCount += 1
        isRecording = false
        return stopResult
    }
}
