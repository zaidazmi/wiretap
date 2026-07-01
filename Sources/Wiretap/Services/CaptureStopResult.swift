import Foundation

struct CaptureStopResult {
    var duration: TimeInterval = 0
    var capturedFrameCount: Int64 = 0
    var droppedFrameCount: Int64 = 0
    var writeError: Error?

    var didCaptureFrames: Bool {
        capturedFrameCount > 0
    }
}
