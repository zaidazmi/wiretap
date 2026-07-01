import Foundation

enum RecordingInterruptionReason: String, CaseIterable, Sendable {
    case appTermination
    case systemSleep
    case sessionInactive

    var noticeMessage: String {
        switch self {
        case .appTermination:
            "Wiretap quit while a recording was in progress. Source files were retained for recovery."
        case .systemSleep:
            "The Mac was going to sleep, so Wiretap stopped capture and saved the partial recording for review."
        case .sessionInactive:
            "The active macOS session changed, so Wiretap stopped capture and saved the partial recording for review."
        }
    }

    var recoverySummary: String {
        switch self {
        case .appTermination:
            "Interrupted - source files retained before quit"
        case .systemSleep:
            "Interrupted - source files retained before sleep"
        case .sessionInactive:
            "Interrupted - source files retained after session change"
        }
    }
}
