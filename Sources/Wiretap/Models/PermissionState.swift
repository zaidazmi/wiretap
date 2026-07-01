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
            "Wiretap records system output audio and the current default microphone."
        case .ready:
            "System audio and microphone access are available."
        case .denied:
            "Open System Settings to allow audio capture and microphone access."
        }
    }
}
