import Foundation

enum RecordingInterruptionReason: String, CaseIterable, Sendable {
    case appTermination
    case systemSleep
    case sessionInactive
    case audioDeviceChanged
    case systemAudioCaptureFailed
    case unexpectedShutdown

    var noticeMessage: String {
        switch self {
        case .appTermination:
            "Wiretap quit while a recording was in progress. Source files were retained for recovery."
        case .systemSleep:
            "The Mac was going to sleep, so Wiretap stopped capture and saved the partial recording for review."
        case .sessionInactive:
            "The active macOS session changed, so Wiretap stopped capture and saved the partial recording for review."
        case .audioDeviceChanged:
            "Wiretap could not safely continue after the default audio device changed, so it saved the partial recording for review."
        case .systemAudioCaptureFailed:
            "System audio capture stopped unexpectedly, so Wiretap stopped the session before more audio could be missed."
        case .unexpectedShutdown:
            "Wiretap found a recording that did not shut down cleanly. Source files were retained for recovery."
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
        case .audioDeviceChanged:
            "Interrupted - source files retained after audio device change"
        case .systemAudioCaptureFailed:
            "Interrupted - source files retained after system audio capture failed"
        case .unexpectedShutdown:
            "Interrupted - source files retained after unexpected shutdown"
        }
    }
}
