import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

typealias SystemAudioFailureHandler = @MainActor @Sendable (Error) -> Void

protocol SystemAudioTapping: AnyObject, Sendable {
    var isRunning: Bool { get }
    var capturedFrameCount: Int64 { get }

    func prewarm()
    func setRuntimeFailureHandler(_ handler: @escaping SystemAudioFailureHandler)
    func start(writingTo outputURL: URL) async throws
    @discardableResult func stop() -> CaptureStopResult
}

extension SystemAudioTapping {
    func setRuntimeFailureHandler(_: @escaping SystemAudioFailureHandler) {}
}

/// Records the system-audio mix through ScreenCaptureKit.
///
/// ScreenCaptureKit captures the composited system mix at a fixed sample rate:
/// it picks up apps that were already playing before capture started, keeps
/// delivering buffers through silence, and does not follow output-device
/// sample-rate renegotiation (Bluetooth A2DP/HFP switches). Core Audio process
/// taps were tried first and failed on all three counts on real hardware; this
/// mirrors how QuickRecorder, Azayaka, and OBS capture system audio.
final class SystemAudioTap: NSObject, SystemAudioTapping, @unchecked Sendable {
    private static let sampleRate = 48_000.0
    private static let channelCount: AVAudioChannelCount = 2
    private static let shareableContentTimeout: TimeInterval = 1.5

    private let outputQueue = DispatchQueue(label: "dev.zaidazmi.Wiretap.system-audio-capture", qos: .userInitiated)
    private let outputQueueKey = DispatchSpecificKey<Bool>()
    private let stateLock = NSLock()
    private var stream: SCStream?
    // Accessed only on outputQueue. The stream identity prevents callbacks from
    // an asynchronously stopping stream from entering a later recording.
    private var activeStreamID: ObjectIdentifier?
    private var writer: AudioBufferListFileWriter?
    private var timelineOriginSeconds: TimeInterval?
    private var didReceiveAudio = false
    private var cachedDisplay: SCDisplay?
    private var lastContentError: Error?
    private var contentRefreshInProgress = false
    private var permissionRequestState = ScreenCapturePermissionRequestState()
    private var runtimeFailureHandler: SystemAudioFailureHandler?
    private var unexpectedStopError: Error?
    private let logger = WiretapLog.capture

    override init() {
        super.init()
        outputQueue.setSpecific(key: outputQueueKey, value: true)
    }

    var isRunning: Bool {
        onOutputQueue { activeStreamID != nil && writer != nil }
    }

    var capturedFrameCount: Int64 {
        onOutputQueue { writer?.capturedFrameCount ?? 0 }
    }

    /// Resolves shareable content ahead of time so recording can start
    /// synchronously. The first call also surfaces the macOS
    /// Screen & System Audio Recording consent prompt.
    func prewarm() {
        let shouldRequest = stateLock.withLock {
            permissionRequestState.beginPrewarm()
        }
        guard shouldRequest else { return }

        scheduleShareableDisplayRefresh()
    }

    func setRuntimeFailureHandler(_ handler: @escaping SystemAudioFailureHandler) {
        stateLock.withLock {
            runtimeFailureHandler = handler
        }
    }

    func start(writingTo outputURL: URL) async throws {
        guard !isRunning else { return }

        var attemptedStream: SCStream?
        do {
            let display = try await resolveDisplay()

            let configuration = SCStreamConfiguration()
            configuration.width = 2
            configuration.height = 2
            // Only the first screen frame is used as the audio timeline
            // anchor. Throttle subsequent 2×2 frames to avoid running a
            // display-rate video pipeline throughout long audio recordings.
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            configuration.showsCursor = false
            configuration.capturesAudio = true
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = Int(Self.sampleRate)
            configuration.channelCount = Int(Self.channelCount)
            configuration.queueDepth = 5

            let filter = SCContentFilter(
                display: display,
                excludingApplications: [],
                exceptingWindows: []
            )

            guard let inputFormat = AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate,
                channels: Self.channelCount
            ) else {
                throw SystemAudioTapError.unsupportedFormat
            }

            let writer = try AudioBufferListFileWriter(outputURL: outputURL, inputFormat: inputFormat)
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            attemptedStream = stream
            // ScreenCaptureKit errors without a screen output even for
            // audio-only capture; its frames are dropped in the handler.
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: outputQueue)

            stateLock.withLock {
                self.stream = stream
                unexpectedStopError = nil
            }
            onOutputQueue {
                self.activeStreamID = ObjectIdentifier(stream)
                self.writer = writer
                self.timelineOriginSeconds = nil
                self.didReceiveAudio = false
            }

            try await stream.startCapture()
            try Task.checkCancellation()
            let streamState = stateLock.withLock {
                (
                    isCurrent: self.stream === stream,
                    stopError: unexpectedStopError
                )
            }
            if let stopError = streamState.stopError {
                throw stopError
            }
            guard streamState.isCurrent else { throw CancellationError() }

            logger.info(
                "System audio capture started format=\(WiretapLog.audioFormatSummary(inputFormat), privacy: .public) output=\(outputURL.lastPathComponent, privacy: .public)"
            )
        } catch {
            let mappedError = SystemAudioTapError.map(error)
            logger.error("System audio capture failed: \(mappedError.localizedDescription, privacy: .public)")
            if let attemptedStream {
                stopStream(attemptedStream)
            }
            onOutputQueue {
                if let attemptedStream,
                   let activeStreamID = self.activeStreamID,
                   activeStreamID != ObjectIdentifier(attemptedStream) {
                    return
                }
                self.activeStreamID = nil
                self.writer = nil
                self.timelineOriginSeconds = nil
                self.didReceiveAudio = false
            }
            throw mappedError
        }
    }

    @discardableResult
    func stop() -> CaptureStopResult {
        stopStream()
        let writer = onOutputQueue {
            let writer = self.writer
            self.activeStreamID = nil
            self.writer = nil
            self.timelineOriginSeconds = nil
            self.didReceiveAudio = false
            return writer
        }

        let flushResult = writer?.flush()
        let result = CaptureStopResult(
            capturedFrameCount: flushResult?.capturedFrameCount ?? 0,
            droppedFrameCount: flushResult?.droppedFrameCount ?? 0,
            writeError: flushResult?.writeError
        )

        if writer != nil {
            logger.info(
                "System audio capture stopped capturedFrames=\(result.capturedFrameCount, privacy: .public) droppedFrames=\(result.droppedFrameCount, privacy: .public) writeError=\(result.writeError?.localizedDescription ?? "none", privacy: .public)"
            )
        }

        return result
    }

    private func stopStream(_ expectedStream: SCStream? = nil) {
        let stream = stateLock.withLock { () -> SCStream? in
            guard let stream = self.stream,
                  expectedStream == nil || stream === expectedStream
            else { return nil }

            self.stream = nil
            return stream
        }
        guard let stream else { return }

        stream.stopCapture { [weak self] error in
            guard let error else { return }
            self?.logger.info(
                "System audio stream stop reported: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Returns the cached display, or waits briefly for a fresh shareable
    /// content fetch. A fetch blocked on the consent prompt times out and
    /// surfaces as a permission error so the user is pointed at Settings.
    private func resolveDisplay() async throws -> SCDisplay {
        let initialState = stateLock.withLock {
            (
                display: cachedDisplay,
                permissionFailureLatched: permissionRequestState.permissionFailureLatched
            )
        }
        guard !initialState.permissionFailureLatched else {
            throw SystemAudioTapError.permissionDenied
        }
        if let display = initialState.display {
            if CGDisplayIsOnline(display.displayID) != 0 {
                return display
            }

            // Prewarming can outlive an external display. Never reuse an
            // offline SCDisplay, because startCapture otherwise fails even
            // though another online display is available.
            stateLock.withLock {
                if cachedDisplay?.displayID == display.displayID {
                    cachedDisplay = nil
                    lastContentError = nil
                }
            }
        }

        let canAttemptCapture = stateLock.withLock {
            permissionRequestState.canAttemptCapture(
                hasCachedDisplay: cachedDisplay != nil,
                preflightGranted: CGPreflightScreenCaptureAccess()
            )
        }
        guard canAttemptCapture else {
            throw SystemAudioTapError.permissionDenied
        }

        scheduleShareableDisplayRefresh()

        let deadline = Date().addingTimeInterval(Self.shareableContentTimeout)
        while Date() < deadline {
            let snapshot = stateLock.withLock {
                (
                    display: cachedDisplay,
                    error: lastContentError,
                    isRefreshing: contentRefreshInProgress
                )
            }

            if let display = snapshot.display {
                return display
            }
            if let error = snapshot.error {
                if SystemAudioTapError.isPermissionDenied(error) {
                    throw SystemAudioTapError.permissionDenied
                }
                throw error
            }
            if !snapshot.isRefreshing {
                break
            }

            try await Task.sleep(for: .milliseconds(10))
        }

        if let display = stateLock.withLock({ cachedDisplay }) {
            return display
        }

        if let lastContentError = stateLock.withLock({ lastContentError }),
           !SystemAudioTapError.isPermissionDenied(lastContentError) {
            throw lastContentError
        }

        throw SystemAudioTapError.permissionDenied
    }

    private func scheduleShareableDisplayRefresh() {
        let shouldRefresh = stateLock.withLock {
            guard !contentRefreshInProgress,
                  !permissionRequestState.permissionFailureLatched
            else { return false }

            contentRefreshInProgress = true
            lastContentError = nil
            return true
        }
        guard shouldRefresh else { return }

        Task { [weak self] in
            guard let self else { return }

            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false,
                    onScreenWindowsOnly: false
                )
                stateLock.withLock {
                    cachedDisplay = content.displays.first
                    lastContentError = content.displays.isEmpty
                        ? SystemAudioTapError.displayUnavailable
                        : nil
                    contentRefreshInProgress = false
                }
            } catch {
                stateLock.withLock {
                    cachedDisplay = nil
                    lastContentError = error
                    contentRefreshInProgress = false
                    if SystemAudioTapError.isPermissionDenied(error) {
                        permissionRequestState.recordPermissionFailure()
                    }
                }
                logger.info(
                    "Shareable content unavailable: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
    }

    private func recordPermissionFailureIfNeeded(_ error: Error) {
        guard SystemAudioTapError.isPermissionDenied(error) else { return }

        stateLock.withLock {
            cachedDisplay = nil
            lastContentError = error
            permissionRequestState.recordPermissionFailure()
        }
    }

    private func onOutputQueue<T>(_ action: () -> T) -> T {
        if DispatchQueue.getSpecific(key: outputQueueKey) == true {
            return action()
        }

        return outputQueue.sync(execute: action)
    }
}

struct ScreenCapturePermissionRequestState: Equatable {
    private(set) var prewarmAttempted = false
    private(set) var permissionFailureLatched = false

    mutating func beginPrewarm() -> Bool {
        guard !prewarmAttempted, !permissionFailureLatched else { return false }
        prewarmAttempted = true
        return true
    }

    func canAttemptCapture(hasCachedDisplay: Bool, preflightGranted: Bool) -> Bool {
        !permissionFailureLatched && (hasCachedDisplay || preflightGranted)
    }

    mutating func recordPermissionFailure() {
        permissionFailureLatched = true
    }
}

extension SystemAudioTap: SCStreamDelegate, SCStreamOutput {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        recordPermissionFailureIfNeeded(error)
        let handler = stateLock.withLock { () -> SystemAudioFailureHandler? in
            guard self.stream === stream else { return nil }

            self.stream = nil
            unexpectedStopError = error
            return runtimeFailureHandler
        }
        guard let handler else { return }

        onOutputQueue {
            if activeStreamID == ObjectIdentifier(stream) {
                activeStreamID = nil
            }
        }
        logger.error(
            "System audio stream stopped unexpectedly: \(error.localizedDescription, privacy: .public)"
        )
        let mappedError = SystemAudioTapError.map(error)
        Task { @MainActor in
            handler(mappedError)
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard activeStreamID == ObjectIdentifier(stream),
              sampleBuffer.isValid,
              let writer
        else { return }

        let presentationTime = sampleBuffer.presentationTimeStamp
        if type == .screen {
            guard !didReceiveAudio,
                  timelineOriginSeconds == nil,
                  presentationTime.isValid,
                  presentationTime.seconds.isFinite
            else { return }

            timelineOriginSeconds = presentationTime.seconds
            return
        }

        guard type == .audio else { return }

        // The buffer-list pointers are only valid inside this scope; the
        // writer copies synchronously before queueing the file write.
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let streamDescription = sampleBuffer.formatDescription?.audioStreamBasicDescription,
                      let format = AVAudioFormat(
                        standardFormatWithSampleRate: streamDescription.mSampleRate,
                        channels: max(1, streamDescription.mChannelsPerFrame)
                      ),
                      let buffer = AVAudioPCMBuffer(
                        pcmFormat: format,
                        bufferListNoCopy: audioBufferList.unsafePointer
                      )
                else {
                    throw SystemAudioTapError.unsupportedFormat
                }

                let sampleTime = SystemAudioSampleClock.sampleTime(
                    presentationTime: presentationTime,
                    sampleRate: format.sampleRate
                )
                if !didReceiveAudio {
                    if let timelineOriginSeconds {
                        writer.anchorTimeline(at: timelineOriginSeconds * format.sampleRate)
                    }
                    didReceiveAudio = true
                    self.timelineOriginSeconds = nil
                }
                writer.write(
                    buffer: buffer,
                    sampleTime: sampleTime,
                    bufferStartUptime: presentationTime.seconds
                )
            }
        } catch {
            let frameCount = AVAudioFrameCount(clamping: max(0, sampleBuffer.numSamples))
            writer.recordDroppedFrames(
                frameCount,
                error: .sampleBufferUnavailable(frameCount: frameCount)
            )
            logger.error(
                "System audio sample buffer unavailable frames=\(frameCount, privacy: .public) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

enum SystemAudioSampleClock {
    static func sampleTime(
        presentationTime: CMTime,
        sampleRate: Double
    ) -> Float64? {
        guard presentationTime.isValid,
              presentationTime.seconds.isFinite,
              sampleRate.isFinite,
              sampleRate > 0
        else { return nil }

        return presentationTime.seconds * sampleRate
    }
}

enum SystemAudioTapError: LocalizedError {
    case permissionDenied
    case displayUnavailable
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Wiretap does not have permission to record system audio. Allow Wiretap under Privacy & Security > Screen & System Audio Recording, then relaunch Wiretap."
        case .displayUnavailable:
            "Wiretap could not find a display to capture system audio from."
        case .unsupportedFormat:
            "Wiretap could not create the system-audio capture format."
        }
    }

    static func map(_ error: Error) -> Error {
        if isPermissionDenied(error) {
            return SystemAudioTapError.permissionDenied
        }

        return error
    }

    static func isPermissionDenied(_ error: Error) -> Bool {
        if case SystemAudioTapError.permissionDenied = error {
            return true
        }

        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userDeclined.rawValue {
            return true
        }

        if let error = error as? AudioHardwareError {
            return error.error == kAudioDevicePermissionsError
        }

        if let error = error as? CoreAudioStatusError {
            return error.status == kAudioDevicePermissionsError
        }

        return false
    }
}

struct CoreAudioStatusError: LocalizedError {
    let status: OSStatus
    let operation: String

    var errorDescription: String? {
        "Core Audio failed to \(operation) (OSStatus \(status))."
    }
}
