import AVFoundation
import Foundation

@MainActor
protocol AudioPlaybackControlling: AnyObject {
    var recordingID: Recording.ID? { get }
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get }
    var duration: TimeInterval { get }

    func toggle(recording: Recording) throws
    func seek(to progress: Double)
    func stop()
}

@MainActor
protocol AudioPlaying: AnyObject {
    var isPlaying: Bool { get }
    var currentTime: TimeInterval { get set }
    var duration: TimeInterval { get }

    func prepareToPlay() -> Bool
    func play() -> Bool
    func pause()
    func stop()
}

extension AVAudioPlayer: AudioPlaying {}

enum AudioPlaybackError: LocalizedError {
    case playbackCouldNotStart

    var errorDescription: String? {
        switch self {
        case .playbackCouldNotStart:
            "Wiretap could not start playback for this recording."
        }
    }
}

@MainActor
final class AudioPlaybackController: AudioPlaybackControlling {
    private let makePlayer: (URL) throws -> any AudioPlaying
    private var player: (any AudioPlaying)?
    private(set) var recordingID: Recording.ID?

    init(makePlayer: @escaping (URL) throws -> any AudioPlaying = { url in
        try AVAudioPlayer(contentsOf: url)
    }) {
        self.makePlayer = makePlayer
    }

    var isPlaying: Bool {
        player?.isPlaying == true
    }

    var currentTime: TimeInterval {
        player?.currentTime ?? 0
    }

    var duration: TimeInterval {
        player?.duration ?? 0
    }

    func toggle(recording: Recording) throws {
        guard let fileURL = recording.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else {
            throw RecordingLibraryError.missingFile
        }

        if recordingID == recording.id, let player {
            if player.isPlaying {
                player.pause()
            } else {
                if player.currentTime >= player.duration {
                    player.currentTime = 0
                }
                try start(player)
            }
            return
        }

        let player = try makePlayer(fileURL)
        _ = player.prepareToPlay()
        try start(player)

        self.player = player
        self.recordingID = recording.id
    }

    func seek(to progress: Double) {
        guard let player else { return }
        player.currentTime = max(0, min(player.duration, player.duration * progress))
    }

    func stop() {
        player?.stop()
        player = nil
        recordingID = nil
    }

    private func start(_ player: any AudioPlaying) throws {
        guard player.play() else {
            throw AudioPlaybackError.playbackCouldNotStart
        }
    }
}
