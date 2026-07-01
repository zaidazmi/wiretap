import AppKit
import AVFoundation
import Foundation

struct PermissionManager {
    func currentState() -> PermissionState {
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

    func requestMicrophoneAccess() async -> PermissionState {
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

    func openPrivacySettings(_ target: PrivacySettingsTarget = .microphone) {
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
                "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AudioCapture",
                "x-apple.systempreferences:com.apple.preference.security?Privacy",
                "x-apple.systempreferences:com.apple.preference.security"
            ]
        }
    }
}
