import AVFoundation
import Foundation

struct AudioMixerWriter {
    func mix(inputs: [AudioMixerInput], outputURL: URL) async throws -> AudioMixResult {
        let existingInputs = inputs.filter { FileManager.default.fileExists(atPath: $0.url.path) }
        guard !existingInputs.isEmpty else {
            throw RecordingLibraryError.missingFile
        }

        var usableInputs: [(input: AudioMixerInput, asset: AVURLAsset, track: AVAssetTrack, duration: CMTime)] = []

        for input in existingInputs {
            let asset = AVURLAsset(url: input.url)
            let tracks: [AVAssetTrack]
            do {
                tracks = try await asset.loadTracks(withMediaType: .audio)
            } catch {
                continue
            }
            guard let track = tracks.first else { continue }

            let duration: CMTime
            do {
                duration = try await asset.load(.duration)
            } catch {
                continue
            }
            guard duration.seconds.isFinite, duration.seconds > 0 else { continue }

            usableInputs.append((input, asset, track, duration))
        }

        guard !usableInputs.isEmpty else {
            throw RecordingLibraryError.missingFile
        }

        if usableInputs.count == 1 {
            if FileManager.default.fileExists(atPath: outputURL.path) {
                try FileManager.default.removeItem(at: outputURL)
            }
            try FileManager.default.copyItem(at: usableInputs[0].input.url, to: outputURL)
            let duration = try await duration(of: outputURL)
            return AudioMixResult(duration: duration, sources: [usableInputs[0].input.source])
        }

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let composition = AVMutableComposition()
        var longestDuration = CMTime.zero

        for input in usableInputs {
            guard let compositionTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
            )
            else { continue }

            longestDuration = max(longestDuration, input.duration)

            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: input.duration),
                of: input.track,
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
        return AudioMixResult(
            duration: longestDuration.seconds,
            sources: usableInputs.map(\.input.source)
        )
    }

    private func duration(of url: URL) async throws -> TimeInterval {
        let asset = AVURLAsset(url: url)
        return try await asset.load(.duration).seconds
    }
}

struct AudioMixerInput: Sendable, Equatable {
    var url: URL
    var source: RecordingSource
}

struct AudioMixResult: Sendable, Equatable {
    var duration: TimeInterval
    var sources: [RecordingSource]
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
