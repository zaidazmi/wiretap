import CoreAudio
import AVFAudio
@testable import Wiretap
import XCTest

final class MicrophoneCapturePolicyTests: XCTestCase {
    func testBuiltInSpeakersUseEchoCancellation() {
        let route = MicrophoneOutputRoute(
            name: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeSpeaker]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .echoCancelled)
    }

    func testBluetoothOutputKeepsRawCapture() {
        let route = MicrophoneOutputRoute(
            name: "Wireless Audio",
            transportType: kAudioDeviceTransportTypeBluetooth,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .raw)
    }

    func testHeadphoneTerminalUsesRawCaptureWithoutLocalizedNameMatching() {
        let route = MicrophoneOutputRoute(
            name: "Auriculares externos",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .raw)
    }

    func testHeadphoneNameIsFallbackWhenTerminalMetadataIsMissing() {
        let route = MicrophoneOutputRoute(
            name: "USB Headset",
            transportType: kAudioDeviceTransportTypeUSB
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .raw)
    }

    func testUnknownOutputRequiresEchoCancellation() {
        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: nil), .echoCancelled)
    }

    func testVoiceProcessingDownmixesBuiltInMicrophoneArrayToMono() throws {
        let captureFormat = try XCTUnwrap(
            MicrophoneVoiceProcessingFormat.captureFormat(
                sampleRate: 48_000,
                hardwareChannelCount: 9
            )
        )

        XCTAssertEqual(captureFormat.sampleRate, 48_000)
        XCTAssertEqual(captureFormat.channelCount, 1)
        XCTAssertEqual(captureFormat.commonFormat, .pcmFormatFloat32)
        XCTAssertFalse(captureFormat.isInterleaved)
    }
}
