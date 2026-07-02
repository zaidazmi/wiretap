import AVFoundation
@testable import Wiretap
import XCTest

final class WiretapLogTests: XCTestCase {
    func testAudioFormatSummaryIncludesRateChannelsFormatAndLayout() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ))

        XCTAssertEqual(
            WiretapLog.audioFormatSummary(format),
            "48000 Hz, 2 channels, float32, non-interleaved"
        )
    }

    func testSourceSummaryUsesStableOrder() {
        XCTAssertEqual(
            WiretapLog.sourceSummary(Set<RecordingSource>([.microphone, .systemAudio])),
            "microphone+systemAudio"
        )
    }
}
