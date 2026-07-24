import CoreAudio
import CoreMedia
import ScreenCaptureKit
@testable import Wiretap
import XCTest

final class SystemAudioTapErrorTests: XCTestCase {
    func testScreenCapturePermissionRequestStatePreventsRepeatedPrompts() {
        var state = ScreenCapturePermissionRequestState()

        XCTAssertTrue(state.beginPrewarm())
        XCTAssertFalse(state.beginPrewarm())
        XCTAssertFalse(state.canAttemptCapture(
            hasCachedDisplay: false,
            preflightGranted: false
        ))

        state.recordPermissionFailure()

        XCTAssertFalse(state.beginPrewarm())
        XCTAssertFalse(state.canAttemptCapture(
            hasCachedDisplay: false,
            preflightGranted: true
        ))
        XCTAssertFalse(state.canAttemptCapture(
            hasCachedDisplay: true,
            preflightGranted: true
        ))
    }

    func testScreenCapturePermissionRequestStateAllowsGrantedOrCachedCapture() {
        let state = ScreenCapturePermissionRequestState()

        XCTAssertTrue(state.canAttemptCapture(
            hasCachedDisplay: false,
            preflightGranted: true
        ))
        XCTAssertTrue(state.canAttemptCapture(
            hasCachedDisplay: true,
            preflightGranted: false
        ))
    }

    func testPermissionErrorsAreRecognizedAcrossCaptureWrappers() {
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(SystemAudioTapError.permissionDenied))
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.userDeclined.rawValue
        )))
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(AudioHardwareError(kAudioDevicePermissionsError)))
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(CoreAudioStatusError(
            status: kAudioDevicePermissionsError,
            operation: "start tap"
        )))
        XCTAssertFalse(SystemAudioTapError.isPermissionDenied(CoreAudioStatusError(
            status: kAudioHardwareUnsupportedOperationError,
            operation: "start tap"
        )))
        XCTAssertFalse(SystemAudioTapError.isPermissionDenied(NSError(
            domain: SCStreamErrorDomain,
            code: SCStreamError.Code.attemptToStopStreamState.rawValue
        )))
    }

    func testCaptureSourceStateLabelsAreUserVisible() {
        XCTAssertEqual(CaptureSourceState.notChecked.label, "Not checked")
        XCTAssertEqual(CaptureSourceState.ready.label, "Ready")
        XCTAssertEqual(CaptureSourceState.unavailable.label, "Unavailable")
    }

    func testSystemAudioSampleClockUsesDeliveredSampleRate() {
        let presentationTime = CMTime(seconds: 2.5, preferredTimescale: 48_000)

        XCTAssertEqual(
            SystemAudioSampleClock.sampleTime(
                presentationTime: presentationTime,
                sampleRate: 16_000
            ),
            40_000
        )
        XCTAssertEqual(
            SystemAudioSampleClock.sampleTime(
                presentationTime: presentationTime,
                sampleRate: 48_000
            ),
            120_000
        )
    }

    func testSystemAudioSampleClockRejectsInvalidInputs() {
        XCTAssertNil(SystemAudioSampleClock.sampleTime(
            presentationTime: .invalid,
            sampleRate: 48_000
        ))
        XCTAssertNil(SystemAudioSampleClock.sampleTime(
            presentationTime: .zero,
            sampleRate: 0
        ))
    }
}
