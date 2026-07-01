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

    func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
