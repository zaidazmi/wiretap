import Foundation

enum PermissionState: Hashable {
    case notReviewed
    case ready
    case denied

    var title: String {
        switch self {
        case .notReviewed: "Permissions Ready to Review"
        case .ready: "Permissions Ready"
        case .denied: "Permissions Denied"
        }
    }

    var summary: String {
        switch self {
        case .notReviewed:
            "Wiretap can record system output audio and the current default microphone."
        case .ready:
            "Microphone access is ready. System audio permission is checked when recording starts."
        case .denied:
            "Open System Settings to allow microphone access. System audio may also require Audio Capture approval."
        }
    }
}
