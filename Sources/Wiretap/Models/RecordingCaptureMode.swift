import Foundation

enum RecordingCaptureMode: String, CaseIterable, Identifiable, Hashable, Sendable {
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

    var onboardingSubtitle: String {
        switch self {
        case .systemAndMicrophone:
            return "System output audio and the default microphone."
        case .systemOnly:
            return "System output audio, without microphone input."
        case .microphoneOnly:
            return "Default microphone, without system output audio."
        }
    }

    var emptyLibraryDescription: String {
        switch self {
        case .systemAndMicrophone:
            return "Start a local recording when you are ready to capture system audio and the default microphone."
        case .systemOnly:
            return "Start a local recording when you are ready to capture audio playing on this Mac."
        case .microphoneOnly:
            return "Start a local recording when you are ready to capture the default microphone."
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
