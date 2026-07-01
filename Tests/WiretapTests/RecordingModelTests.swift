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
}
