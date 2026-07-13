import AppKit
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
        let audioDeviceMonitor = FakeAudioDeviceChangeMonitor()
        var context = makeLifecycleContext(audioDeviceMonitor: audioDeviceMonitor)

        context.store.startRecording()
        audioDeviceMonitor.triggerChange()

        try assertInterruptedRecording(
            in: context.store,
            sourceSummary: "Interrupted - source files retained after audio device change",
            noticeText: "default audio device changed"
        )
        XCTAssertNotNil(context.lifecycleMonitor)
        XCTAssertEqual(context.microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(context.systemAudioTap.stopCallCount, 1)

        context.lifecycleMonitor = nil

        XCTAssertEqual(audioDeviceMonitor.stopCallCount, 1)
    }

    @MainActor
    func testApplicationTerminationPreservesActiveRecording() throws {
        let notificationCenter = NotificationCenter()
        let context = makeLifecycleContext(notificationCenter: notificationCenter)

        context.store.startRecording()
        notificationCenter.post(name: NSApplication.willTerminateNotification, object: nil)

        try assertInterruptedRecording(
            in: context.store,
            sourceSummary: "Interrupted - source files retained before quit",
            noticeText: "quit while a recording was in progress"
        )
        XCTAssertEqual(context.microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(context.systemAudioTap.stopCallCount, 1)
    }

    @MainActor
    func testSystemSleepPreservesActiveRecordingSynchronously() throws {
        let workspaceNotificationCenter = NotificationCenter()
        let context = makeLifecycleContext(workspaceNotificationCenter: workspaceNotificationCenter)

        context.store.startRecording()
        workspaceNotificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)

        try assertInterruptedRecording(
            in: context.store,
            sourceSummary: "Interrupted - source files retained before sleep",
            noticeText: "Mac was going to sleep"
        )
        XCTAssertEqual(context.microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(context.systemAudioTap.stopCallCount, 1)
    }

    @MainActor
    func testSessionInactivePreservesActiveRecordingSynchronously() throws {
        let workspaceNotificationCenter = NotificationCenter()
        let context = makeLifecycleContext(workspaceNotificationCenter: workspaceNotificationCenter)

        context.store.startRecording()
        workspaceNotificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)

        try assertInterruptedRecording(
            in: context.store,
            sourceSummary: "Interrupted - source files retained after session change",
            noticeText: "active macOS session changed"
        )
        XCTAssertEqual(context.microphoneRecorder.stopCallCount, 1)
        XCTAssertEqual(context.systemAudioTap.stopCallCount, 1)
    }

    @MainActor
    private func makeLifecycleContext(
        notificationCenter: NotificationCenter = NotificationCenter(),
        workspaceNotificationCenter: NotificationCenter = NotificationCenter(),
        audioDeviceMonitor: FakeAudioDeviceChangeMonitor = FakeAudioDeviceChangeMonitor()
    ) -> LifecycleContext {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let microphoneRecorder = MonitorFakeMicrophoneRecorder()
        let systemAudioTap = MonitorFakeSystemAudioTap()
        let store = WiretapStore(
            repository: repository,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap,
            permissionManager: PermissionManager(currentState: { .ready }),
            minimumFreeDiskSpaceBytes: 0
        )
        let lifecycleMonitor = RecordingLifecycleMonitor(
            store: store,
            notificationCenter: notificationCenter,
            workspaceNotificationCenter: workspaceNotificationCenter,
            audioDeviceChangeMonitor: audioDeviceMonitor
        )

        return LifecycleContext(
            store: store,
            lifecycleMonitor: lifecycleMonitor,
            microphoneRecorder: microphoneRecorder,
            systemAudioTap: systemAudioTap
        )
    }

    @MainActor
    private func assertInterruptedRecording(
        in store: WiretapStore,
        sourceSummary: String,
        noticeText: String
    ) throws {
        let recording = try XCTUnwrap(store.recordings.first)
        XCTAssertFalse(store.isRecording)
        XCTAssertEqual(recording.status, .interrupted)
        XCTAssertNil(recording.fileURL)
        XCTAssertNotNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.sourceSummary, sourceSummary)
        XCTAssertEqual(store.notice?.title, "Recording Interrupted")
        XCTAssertTrue(store.notice?.message.localizedStandardContains(noticeText) == true)
    }
}

private struct LifecycleContext {
    let store: WiretapStore
    var lifecycleMonitor: RecordingLifecycleMonitor?
    let microphoneRecorder: MonitorFakeMicrophoneRecorder
    let systemAudioTap: MonitorFakeSystemAudioTap
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

    func prewarm() {}

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
