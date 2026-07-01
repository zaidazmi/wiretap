import Foundation
@testable import Wiretap
import XCTest

final class RecordingLifecycleMonitorTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingLifecycleMonitorTests-\(UUID().uuidString)", isDirectory: true)
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
    func testAudioDeviceChangePreservesActiveRecording() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let audioDeviceMonitor = FakeAudioDeviceChangeMonitor()
        let microphoneRecorder = MonitorFakeMicrophoneRecorder()
        let systemAudioTap = MonitorFakeSystemAudioTap()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )
        var lifecycleMonitor: RecordingLifecycleMonitor? = RecordingLifecycleMonitor(
            store: store,
            notificationCenter: NotificationCenter(),
            workspaceNotificationCenter: NotificationCenter(),
            audioDeviceChangeMonitor: audioDeviceMonitor
        )

        store.startRecording()
        audioDeviceMonitor.triggerChange()

        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertNotNil(lifecycleMonitor)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.sourceSummary, "Interrupted - source files retained after audio device change")
        XCTAssertEqual(store.notice?.title, "Recording Interrupted")
        XCTAssertTrue(store.notice?.message.localizedStandardContains("default audio device changed") == true)
        XCTAssertEqual(microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(systemAudioTap.stopCallCount, 1)

        lifecycleMonitor = nil

        XCTAssertEqual(audioDeviceMonitor.stopCallCount, 1)
    }
}

private final class FakeAudioDeviceChangeMonitor: AudioDeviceChangeMonitoring {
    private var onChange: AudioDeviceChangeHandler?
    var stopCallCount = 0

    func start(onChange: @escaping AudioDeviceChangeHandler) {
        self.onChange = onChange
    }

    func stop() {
        stopCallCount += 1
        onChange = nil
    }

    @MainActor
    func triggerChange() {
        onChange?()
    }
}

private final class MonitorFakeSystemAudioTap: SystemAudioTapping {
    var isRunning = false
    var capturedFrameCount: Int64 = 48_000
    var stopCallCount = 0

    func start(writingTo outputURL: URL) throws {
        try Data("system".utf8).write(to: outputURL)
        isRunning = true
    }

    @discardableResult
    func stop() -> CaptureStopResult {
        stopCallCount += 1
        isRunning = false
        return CaptureStopResult(capturedFrameCount: capturedFrameCount)
    }
}

private final class MonitorFakeMicrophoneRecorder: MicrophoneRecording {
    var isRecording = false
    var capturedFrameCount: Int64 = 48_000
    var stopCallCount = 0

    func startRecording(to url: URL) throws {
        try Data("microphone".utf8).write(to: url)
        isRecording = true
    }

    @discardableResult
    func stopRecording() -> CaptureStopResult {
        stopCallCount += 1
        isRecording = false
        return CaptureStopResult(duration: 1, capturedFrameCount: capturedFrameCount)
    }
}
