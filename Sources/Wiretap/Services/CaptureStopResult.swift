import Foundation

struct CaptureStopResult {
    var duration: TimeInterval = 0
    var capturedFrameCount: Int64 = 0
    var droppedFrameCount: Int64 = 0
    var writeError: Error?
    var microphonePostProcessing: MicrophonePostProcessing = .none

    var didCaptureFrames: Bool {
        // The writer includes rejected frames in capturedFrameCount so drop
        // ratios use the total observed timeline. A source is usable only when
        // at least one of those frames was actually accepted for writing.
        capturedFrameCount > droppedFrameCount
    }
}

enum MicrophonePostProcessing: String, Sendable, Equatable {
    case none
    case soundIsolation
}

enum CaptureDropRecoveryPolicy {
    private static let alwaysRecoverableFrameCount: Int64 = 2_048
    private static let maximumRecoverableFrameCount: Int64 = 12_000
    private static let maximumRecoverableFraction = 0.005

    static func canRecover(_ result: CaptureStopResult) -> Bool {
        let droppedFrames = result.droppedFrameCount
        guard droppedFrames > 0 else { return true }

        if droppedFrames <= alwaysRecoverableFrameCount {
            return true
        }

        guard droppedFrames <= maximumRecoverableFrameCount,
              result.capturedFrameCount > 0
        else { return false }

        return Double(droppedFrames) / Double(result.capturedFrameCount)
            <= maximumRecoverableFraction
    }

    static func canRecover(_ error: Error, result: CaptureStopResult) -> Bool {
        guard let writerError = error as? AudioBufferListFileWriterError else {
            return false
        }

        switch writerError {
        case .bufferPoolExhausted, .sampleBufferUnavailable:
            break
        case .bufferExceedsPoolCapacity, .formatConversionFailed:
            return false
        }

        return canRecover(result)
    }
}
