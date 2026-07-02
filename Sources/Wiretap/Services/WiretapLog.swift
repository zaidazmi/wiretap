import AVFoundation
import os

enum WiretapLog {
    static let capture = Logger(subsystem: "dev.zaidazmi.Wiretap", category: "Capture")
    static let mixer = Logger(subsystem: "dev.zaidazmi.Wiretap", category: "Mixer")

    static func audioFormatSummary(_ format: AVAudioFormat) -> String {
        let sampleRate = Int(format.sampleRate.rounded())
        let channelText = Int(format.channelCount) == 1 ? "1 channel" : "\(format.channelCount) channels"
        let layoutText = format.isInterleaved ? "interleaved" : "non-interleaved"

        return "\(sampleRate) Hz, \(channelText), \(commonFormatName(format.commonFormat)), \(layoutText)"
    }

    static func sourceSummary(_ sources: some Collection<RecordingSource>) -> String {
        sources
            .sorted { $0.rawValue < $1.rawValue }
            .map(\.rawValue)
            .joined(separator: "+")
    }

    private static func commonFormatName(_ format: AVAudioCommonFormat) -> String {
        switch format {
        case .otherFormat:
            "other"
        case .pcmFormatFloat32:
            "float32"
        case .pcmFormatFloat64:
            "float64"
        case .pcmFormatInt16:
            "int16"
        case .pcmFormatInt32:
            "int32"
        @unknown default:
            "unknown"
        }
    }
}
