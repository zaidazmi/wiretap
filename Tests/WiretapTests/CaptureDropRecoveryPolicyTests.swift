import AVFoundation
import XCTest
@testable import Wiretap

final class CaptureDropRecoveryPolicyTests: XCTestCase {
    func testRecoversObservedShortMicrophonePoolExhaustion() {
        let result = CaptureStopResult(
            capturedFrameCount: 502_272,
            droppedFrameCount: 1_536,
            writeError: AudioBufferListFileWriterError.bufferPoolExhausted(frameCount: 512)
        )

        XCTAssertTrue(CaptureDropRecoveryPolicy.canRecover(result))
        XCTAssertTrue(CaptureDropRecoveryPolicy.canRecover(try XCTUnwrap(result.writeError), result: result))
    }

    func testRejectsSustainedCaptureLoss() {
        let result = CaptureStopResult(
            capturedFrameCount: 48_000,
            droppedFrameCount: 12_000
        )

        XCTAssertFalse(CaptureDropRecoveryPolicy.canRecover(result))
    }

    func testRejectsNonPoolWriteErrorEvenWhenDropIsShort() {
        let result = CaptureStopResult(
            capturedFrameCount: 48_000,
            droppedFrameCount: 512
        )

        XCTAssertFalse(CaptureDropRecoveryPolicy.canRecover(
            AudioBufferListFileWriterError.bufferExceedsPoolCapacity(
                frameCount: 512,
                capacity: 256
            ),
            result: result
        ))
    }
}
