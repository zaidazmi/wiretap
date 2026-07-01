import CoreAudio
@testable import Wiretap
import XCTest

final class SystemAudioTapErrorTests: XCTestCase {
    func testPermissionErrorsAreRecognizedAcrossCoreAudioWrappers() {
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(SystemAudioTapError.permissionDenied))
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(AudioHardwareError(kAudioDevicePermissionsError)))
        XCTAssertTrue(SystemAudioTapError.isPermissionDenied(CoreAudioStatusError(
            status: kAudioDevicePermissionsError,
            operation: "start tap"
        )))
        XCTAssertFalse(SystemAudioTapError.isPermissionDenied(CoreAudioStatusError(
            status: kAudioHardwareUnsupportedOperationError,
            operation: "start tap"
        )))
    }

    func testCaptureSourceStateLabelsAreUserVisible() {
        XCTAssertEqual(CaptureSourceState.notChecked.label, "Not checked")
        XCTAssertEqual(CaptureSourceState.ready.label, "Ready")
        XCTAssertEqual(CaptureSourceState.unavailable.label, "Unavailable")
    }
}
