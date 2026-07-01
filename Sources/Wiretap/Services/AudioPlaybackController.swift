import AVFoundation
import Foundation

@MainActor
final class AudioPlaybackController {
    private var player: AVAudioPlayer?
    private(set) var recordingID: Recording.ID?

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
                player.play()
            }
            return
        }

        let player = try AVAudioPlayer(contentsOf: fileURL)
        player.prepareToPlay()
        player.play()

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
}
