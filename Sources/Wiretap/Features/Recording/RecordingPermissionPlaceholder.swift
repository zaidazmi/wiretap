import Foundation

enum RecordingPermissionPlaceholder: CaseIterable, Identifiable {
    case systemAudio
    case defaultMicrophone

    var id: Self {
        self
    }

    var title: String {
        switch self {
        case .systemAudio:
            return "System Audio"
        case .defaultMicrophone:
            return "Default Microphone"
        }
    }

    var systemImage: String {
        switch self {
        case .systemAudio:
            return "speaker.wave.2.fill"
        case .defaultMicrophone:
            return "mic.fill"
        }
    }

    var copy: String {
        switch self {
        case .systemAudio:
            return "Wiretap will ask before capturing app and system sound."
        case .defaultMicrophone:
            return "Wiretap will use the current default input when recording starts."
        }
    }

    var statusText: String {
        "Not requested"
    }
}
