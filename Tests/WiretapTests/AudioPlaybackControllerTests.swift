import Foundation
@testable import Wiretap
import XCTest

final class AudioPlaybackControllerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapPlaybackTests-\(UUID().uuidString)", isDirectory: true)
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
    func testToggleStartsPausesResumesAndStopsPlayback() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("playback.m4a")
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(fileURL: fileURL)
        let player = FakeAudioPlayer(duration: 1)
        let controller = AudioPlaybackController(makePlayer: { url in
            XCTAssertEqual(url, fileURL)
            return player
        })

        try controller.toggle(recording: recording)

        XCTAssertEqual(controller.recordingID, recording.id)
        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(controller.duration, 1.0, accuracy: 0.15)
        XCTAssertEqual(player.prepareToPlayCallCount, 1)
        XCTAssertEqual(player.playCallCount, 1)

        controller.seek(to: 0.5)

        XCTAssertEqual(controller.currentTime, controller.duration * 0.5, accuracy: 0.15)

        try controller.toggle(recording: recording)

        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.recordingID, recording.id)
        XCTAssertEqual(player.pauseCallCount, 1)

        try controller.toggle(recording: recording)

        XCTAssertTrue(controller.isPlaying)
        XCTAssertEqual(player.playCallCount, 2)

        controller.stop()

        XCTAssertNil(controller.recordingID)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.currentTime, 0)
        XCTAssertEqual(controller.duration, 0)
        XCTAssertEqual(player.stopCallCount, 1)
    }

    @MainActor
    func testToggleThrowsForMissingRecordingFile() {
        let recording = makeRecording(
            fileURL: temporaryDirectory.appendingPathComponent("missing.m4a")
        )
        let controller = AudioPlaybackController()

        XCTAssertThrowsError(try controller.toggle(recording: recording)) { error in
            guard case RecordingLibraryError.missingFile = error else {
                XCTFail("Expected missing file error, got \(error)")
                return
            }
        }
    }

    @MainActor
    func testSeekClampsProgressToPlayableRange() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("seek.m4a")
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(fileURL: fileURL)
        let controller = AudioPlaybackController(makePlayer: { _ in
            FakeAudioPlayer(duration: 1)
        })
        try controller.toggle(recording: recording)

        controller.seek(to: -1)

        XCTAssertEqual(controller.currentTime, 0, accuracy: 0.05)

        controller.seek(to: 2)

        XCTAssertEqual(controller.currentTime, controller.duration, accuracy: 0.05)
    }

    @MainActor
    func testToggleThrowsWhenPlaybackCannotStart() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("unplayable.m4a")
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(fileURL: fileURL)
        let player = FakeAudioPlayer(duration: 1)
        player.canPlay = false
        let controller = AudioPlaybackController(makePlayer: { _ in player })

        XCTAssertThrowsError(try controller.toggle(recording: recording)) { error in
            guard case AudioPlaybackError.playbackCouldNotStart = error else {
                XCTFail("Expected playback start error, got \(error)")
                return
            }
        }
        XCTAssertNil(controller.recordingID)
        XCTAssertFalse(controller.isPlaying)
    }

    @MainActor
    func testPlaybackRateAppliesBeforeStartAndChangesDuringPlayback() throws {
        let fileURL = temporaryDirectory.appendingPathComponent("playback-rate.m4a")
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(fileURL: fileURL)
        let player = FakeAudioPlayer(duration: 10)
        let controller = AudioPlaybackController(makePlayer: { _ in player })

        controller.setPlaybackRate(.onePointTwentyFour)
        try controller.toggle(recording: recording)

        XCTAssertEqual(controller.playbackRate, .onePointTwentyFour)
        XCTAssertTrue(player.enableRate)
        XCTAssertEqual(player.rate, 1.24, accuracy: 0.001)

        controller.setPlaybackRate(.double)

        XCTAssertEqual(controller.playbackRate, .double)
        XCTAssertEqual(player.rate, 2, accuracy: 0.001)
    }

    func testPlaybackRateOptionsMatchSupportedSpeeds() {
        XCTAssertEqual(PlaybackRate.allCases.map(\.rawValue), [1, 1.1, 1.24, 1.5, 2])
        XCTAssertEqual(PlaybackRate.allCases.map(\.label), ["1×", "1.1×", "1.24×", "1.5×", "2×"])
    }

    private func makeRecording(fileURL: URL) -> Recording {
        Recording(
            title: "Playback",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 1,
            fileURL: fileURL,
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
    }

}

@MainActor
private final class FakeAudioPlayer: AudioPlaying {
    var isPlaying = false
    var currentTime: TimeInterval = 0
    let duration: TimeInterval
    var enableRate = false
    var rate: Float = 1
    var canPlay = true
    var prepareToPlayCallCount = 0
    var playCallCount = 0
    var pauseCallCount = 0
    var stopCallCount = 0

    init(duration: TimeInterval) {
        self.duration = duration
    }

    func prepareToPlay() -> Bool {
        prepareToPlayCallCount += 1
        return true
    }

    func play() -> Bool {
        playCallCount += 1
        isPlaying = canPlay
        return canPlay
    }

    func pause() {
        pauseCallCount += 1
        isPlaying = false
    }

    func stop() {
        stopCallCount += 1
        isPlaying = false
        currentTime = 0
    }
}
