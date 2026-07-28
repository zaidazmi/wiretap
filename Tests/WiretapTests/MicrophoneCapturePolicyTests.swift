import AVFoundation
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

    func testBluetoothSpeakerUsesSoundIsolation() {
        let route = MicrophoneOutputRoute(
            name: "JBL Flip 6",
            transportType: kAudioDeviceTransportTypeBluetooth,
            terminalTypes: [kAudioStreamTerminalTypeSpeaker]
        )

        XCTAssertEqual(MicrophoneCapturePolicy.mode(for: route), .speakerProcessed)
        XCTAssertEqual(MicrophoneCapturePolicy.postProcessing(for: route), .soundIsolation)
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

    func testActiveVoIPUsesCanonicalFallbackForUnrepresentableDeviceFormat() throws {
        var callModeDescription = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 12,
            mFramesPerPacket: 1,
            mBytesPerFrame: 12,
            mChannelsPerFrame: 3,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        XCTAssertNil(AVAudioFormat(streamDescription: &callModeDescription))

        let resolution = try XCTUnwrap(MicrophoneInputFormatResolver.resolve(
            streamDescriptions: [callModeDescription],
            nominalSampleRate: 48_000
        ))

        XCTAssertTrue(resolution.usedFallback)
        XCTAssertEqual(resolution.format.sampleRate, 48_000)
        XCTAssertEqual(resolution.format.channelCount, 1)
        XCTAssertEqual(resolution.format.commonFormat, .pcmFormatFloat32)
        XCTAssertTrue(resolution.format.isInterleaved)
    }

    func testValidMicrophoneStreamFormatDoesNotUseFallback() throws {
        let validFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: true
        ))

        let resolution = try XCTUnwrap(MicrophoneInputFormatResolver.resolve(
            streamDescriptions: [validFormat.streamDescription.pointee],
            nominalSampleRate: 48_000
        ))

        XCTAssertFalse(resolution.usedFallback)
        XCTAssertEqual(resolution.format.sampleRate, 16_000)
        XCTAssertEqual(resolution.format.channelCount, 1)
    }

}
