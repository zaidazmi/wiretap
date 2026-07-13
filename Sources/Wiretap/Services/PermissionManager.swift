import AppKit
import AVFoundation
import Foundation

struct PermissionManager: Sendable {
    private var currentStateProvider: @Sendable () -> PermissionState
    private var microphoneAccessRequester: @Sendable () async -> PermissionState
    private var privacySettingsOpener: @Sendable (PrivacySettingsTarget) -> Void

    init(
        currentState: @escaping @Sendable () -> PermissionState = PermissionManager.defaultCurrentState,
        requestMicrophoneAccess: @escaping @Sendable () async -> PermissionState = PermissionManager.defaultRequestMicrophoneAccess,
        openPrivacySettings: @escaping @Sendable (PrivacySettingsTarget) -> Void = PermissionManager.defaultOpenPrivacySettings
    ) {
        self.currentStateProvider = currentState
        self.microphoneAccessRequester = requestMicrophoneAccess
        self.privacySettingsOpener = openPrivacySettings
    }

    func currentState() -> PermissionState {
        currentStateProvider()
    }

    func requestMicrophoneAccess() async -> PermissionState {
        await microphoneAccessRequester()
    }

    func openPrivacySettings(_ target: PrivacySettingsTarget = .microphone) {
        privacySettingsOpener(target)
    }

    private static func defaultCurrentState() -> PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return .ready
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notReviewed
        @unknown default:
            return .notReviewed
        }
    }

    private static func defaultRequestMicrophoneAccess() async -> PermissionState {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return .ready
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            return granted ? .ready : .denied
        @unknown default:
            return .notReviewed
        }
    }

    private static func defaultOpenPrivacySettings(_ target: PrivacySettingsTarget = .microphone) {
        for urlString in target.urlStrings {
            guard let url = URL(string: urlString) else { continue }
            NSWorkspace.shared.open(url)
            return
        }
    }
}

enum PrivacySettingsTarget: Hashable {
    case microphone
    case systemAudio

    fileprivate var urlStrings: [String] {
        switch self {
        case .microphone:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        case .systemAudio:
            [
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        }
    }
}
