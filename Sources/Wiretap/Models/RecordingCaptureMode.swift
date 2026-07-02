import Foundation

enum RecordingCaptureMode: String, CaseIterable, Identifiable, Hashable {
    case systemAndMicrophone
    case systemOnly
    case microphoneOnly

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .systemAndMicrophone:
            return "System + Mic"
        case .systemOnly:
            return "System Only"
        case .microphoneOnly:
            return "Mic Only"
        }
    }

    var detailTitle: String {
        switch self {
        case .systemAndMicrophone:
            return "System audio + default microphone"
        case .systemOnly:
            return "System audio"
        case .microphoneOnly:
            return "Default microphone"
        }
    }

    var sources: Set<RecordingSource> {
        switch self {
        case .systemAndMicrophone:
            return [.systemAudio, .microphone]
        case .systemOnly:
            return [.systemAudio]
        case .microphoneOnly:
            return [.microphone]
        }
    }

    var requiresSystemAudio: Bool {
        sources.contains(.systemAudio)
    }

    var requiresMicrophone: Bool {
        sources.contains(.microphone)
    }
}
