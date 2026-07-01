import AVFoundation
import Foundation

struct AudioMixerWriter {
    func mix(inputURLs: [URL], outputURL: URL) async throws -> TimeInterval {
        let existingInputs = inputURLs.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existingInputs.isEmpty else {
            throw RecordingLibraryError.missingFile
        }

        if existingInputs.count == 1 {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: existingInputs[0], to: outputURL)
            return try await duration(of: outputURL)
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        var longestDuration = CMTime.zero

        for inputURL in existingInputs {
            let asset = AVURLAsset(url: inputURL)
            let tracks = try await asset.loadTracks(withMediaType: .audio)
            guard let sourceTrack = tracks.first,
                  let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                  )
            else { continue }

            let duration = try await asset.load(.duration)
            longestDuration = max(longestDuration, duration)

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: sourceTrack,
                at: .zero
            )
        }

        guard composition.tracks(withMediaType: .audio).isEmpty == false else {
            throw RecordingLibraryError.missingFile
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw AudioMixerWriterError.couldNotCreateExporter
        }

        try await exportSession.export(to: outputURL, as: .m4a)
        return longestDuration.seconds
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }
}

enum AudioMixerWriterError: LocalizedError {
    case couldNotCreateExporter

    var errorDescription: String? {
        switch self {
        case .couldNotCreateExporter:
            "Wiretap could not create the audio exporter."
        }
    }
}
