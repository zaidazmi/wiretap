@testable import Wiretap
import XCTest

final class RecordingModelTests: XCTestCase {
    func testSourceSummaryUsesStablePlanLanguage() {
        XCTAssertEqual(
            Recording.sourceSummary(for: [.systemAudio, .microphone]),
            "System audio + default microphone"
        )
        XCTAssertEqual(
            Recording.sourceSummary(for: [.microphone]),
            "default microphone"
        )
        XCTAssertEqual(
            Recording.sourceSummary(for: []),
            "Recorded audio"
        )
    }

    func testSearchableTextIncludesMissingFileStatus() {
        let recording = Recording(
            title: "Broken",
            createdAt: .distantPast,
            duration: 1,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio",
            status: .missingFile
        )

        XCTAssertTrue(recording.searchableText.localizedStandardContains("Missing File"))
        XCTAssertTrue(recording.searchableText.localizedStandardContains("System audio"))
    }

    func testSearchableTextIncludesInterruptedStatus() {
        let recording = Recording(
            title: "Paused by Sleep",
            createdAt: .distantPast,
            duration: 1,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Interrupted - System audio + default microphone",
            status: .interrupted
        )

        XCTAssertTrue(recording.searchableText.localizedStandardContains("Needs Review"))
        XCTAssertTrue(recording.searchableText.localizedStandardContains("Interrupted"))
    }

    func testInterruptionReasonsHaveRecoverySummaries() {
        XCTAssertEqual(
            RecordingInterruptionReason.appTermination.recoverySummary,
            "Interrupted - source files retained before quit"
        )
        XCTAssertEqual(
            RecordingInterruptionReason.systemSleep.recoverySummary,
            "Interrupted - source files retained before sleep"
        )
        XCTAssertTrue(
            RecordingInterruptionReason.sessionInactive.noticeMessage
                .localizedStandardContains("session changed")
        )
        XCTAssertEqual(
            RecordingInterruptionReason.unexpectedShutdown.recoverySummary,
            "Interrupted - source files retained after unexpected shutdown"
        )
    }

    func testDecodingOlderMetadataDefaultsRecoveryFolderToNil() throws {
        let json = """
        {
          "channelCount" : 2,
          "createdAt" : "2026-07-01T12:00:00Z",
          "duration" : 12,
          "fileSizeBytes" : 1024,
          "fileURL" : "file:///tmp/Wiretap/Recording.m4a",
          "id" : "11111111-1111-1111-1111-111111111111",
          "sampleRate" : 48000,
          "sourceSummary" : "System audio + default microphone",
          "status" : "finalized",
          "title" : "Legacy"
        }
        """

        let recording = try JSONDecoder.wiretapTest.decode(Recording.self, from: Data(json.utf8))

        XCTAssertNil(recording.recoveryFolderURL)
        XCTAssertEqual(recording.title, "Legacy")
    }
}

private extension JSONDecoder {
    static var wiretapTest: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
