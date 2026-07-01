import AVFoundation
import Foundation

final class MicrophoneRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var startedAt: Date?

    var isRecording: Bool {
        recorder?.isRecording == true
    }

    func startRecording(to url: URL) throws {
        stopRecording()

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()

        guard recorder.record() else {
            throw AudioRecordingError.couldNotStart
        }

        self.recorder = recorder
        self.startedAt = Date()
    }

    @discardableResult
    func stopRecording() -> TimeInterval {
        guard let recorder else {
            return 0
        }

        recorder.stop()
        self.recorder = nil

        let duration = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        startedAt = nil
        return duration
    }
}

enum AudioRecordingError: LocalizedError {
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .couldNotStart:
            "Wiretap could not start recording from the default microphone."
        }
    }
}
