import Foundation

enum CaptureSourceState: Hashable {
    case notChecked
    case ready
    case unavailable

    var label: String {
        switch self {
        case .notChecked: "Not checked"
        case .ready: "Ready"
        case .unavailable: "Unavailable"
        }
    }
}
