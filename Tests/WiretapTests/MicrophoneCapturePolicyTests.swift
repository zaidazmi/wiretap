import CoreAudio
@testable import Wiretap
import XCTest

final class MicrophoneCapturePolicyTests: XCTestCase {
    func testBuiltInSpeakersUseEchoCancellation() {
        let route = MicrophoneOutputRoute(
            name: "MacBook Pro Speakers",
            transportType: kAudioDeviceTransportTypeBuiltIn,
            terminalTypes: [kAudioStreamTerminalTypeSpeaker]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .speakerProcessed)
        XCTAssertEqual(MicrophoneCapturePolicy.postProcessing(for: route), .soundIsolation)
    }

    func testBluetoothOutputKeepsRawCapture() {
        let route = MicrophoneOutputRoute(
            name: "Wireless Audio",
            transportType: kAudioDeviceTransportTypeBluetooth,
            terminalTypes: [kAudioStreamTerminalTypeHeadphones]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .raw)
        XCTAssertEqual(MicrophoneCapturePolicy.postProcessing(for: route), .none)
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

    func testUnknownOutputRequiresSpeakerProcessing() {
        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: nil), .speakerProcessed)
        XCTAssertEqual(MicrophoneCapturePolicy.postProcessing(for: nil), .soundIsolation)
    }

    func testFormatObserverCoversVoiceChatChannelAndRateChanges() {
        let selectors = Set(AudioDeviceFormatObserver.devicePropertyAddresses.map(\.mSelector))

        XCTAssertTrue(selectors.contains(kAudioDevicePropertyNominalSampleRate))
        XCTAssertTrue(selectors.contains(kAudioDevicePropertyActualSampleRate))
        XCTAssertTrue(selectors.contains(kAudioDevicePropertyStreams))
        XCTAssertTrue(selectors.contains(kAudioDevicePropertyStreamConfiguration))
        XCTAssertTrue(selectors.contains(kAudioDevicePropertyDeviceHasChanged))
        XCTAssertEqual(
            AudioDeviceFormatObserver.streamVirtualFormatAddress.mSelector,
            kAudioStreamPropertyVirtualFormat
        )
        XCTAssertTrue(
            AudioDeviceFormatObserver.shouldRefreshStreamRegistrations(
                for: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreams,
                    mScope: kAudioObjectPropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        )
        XCTAssertFalse(
            AudioDeviceFormatObserver.shouldRefreshStreamRegistrations(
                for: AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyNominalSampleRate,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
            )
        )
    }

}
