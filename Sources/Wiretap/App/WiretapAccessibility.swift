enum WiretapAccessibility {
    enum Command {
        static let recordToggle = "wiretap.command.recordToggle"
        static let openLibrary = "wiretap.command.openLibrary"
    }

    enum MenuBar {
        static let statusItem = "wiretap.menu.statusItem"
        static let panel = "wiretap.menu.panel"
        static let status = "wiretap.menu.status"
        static let elapsed = "wiretap.menu.elapsed"
        static let recordingCount = "wiretap.menu.recordingCount"
        static let librarySize = "wiretap.menu.librarySize"
        static let noticeBanner = "wiretap.menu.noticeBanner"
        static let noticeDismissButton = "wiretap.menu.notice.dismiss"
        static let noticeRecoveryButton = "wiretap.menu.notice.recovery"
        static let recordButton = "wiretap.menu.record"
        static let stopButton = "wiretap.menu.stop"
        static let permissionsButton = "wiretap.menu.permissions"
        static let openLibraryButton = "wiretap.menu.openLibrary"
        static let quitButton = "wiretap.menu.quit"
        static let systemAudioSource = "wiretap.menu.capture.systemAudio"
        static let microphoneSource = "wiretap.menu.capture.microphone"
    }

    enum Library {
        static let window = "wiretap.library.window"
        static let statusStrip = "wiretap.library.statusStrip"
        static let sidebar = "wiretap.library.sidebar"
        static let recordingList = "wiretap.library.recordingList"
        static let emptyState = "wiretap.library.emptyState"
        static let emptyRecordButton = "wiretap.library.empty.record"
        static let emptyPermissionsButton = "wiretap.library.empty.permissions"
        static let emptyClearSearchButton = "wiretap.library.empty.clearSearch"
        static let statusStopButton = "wiretap.library.status.stop"
        static let toolbarPermissionsButton = "wiretap.library.toolbar.permissions"
        static let toolbarRecordButton = "wiretap.library.toolbar.record"

        static func recordingRow(id: Recording.ID) -> String {
            "wiretap.library.recordingRow.\(id.uuidString)"
        }
    }

    enum Detail {
        static let root = "wiretap.detail.root"
        static let titleField = "wiretap.detail.title"
        static let player = "wiretap.detail.player"
        static let playPauseButton = "wiretap.detail.player.playPause"
        static let seekSlider = "wiretap.detail.player.seek"
        static let revealButton = "wiretap.detail.reveal"
        static let exportButton = "wiretap.detail.export"
        static let shareButton = "wiretap.detail.share"
        static let deleteButton = "wiretap.detail.delete"
        static let recoveryPanel = "wiretap.detail.recovery"
        static let recoveryRevealButton = "wiretap.detail.recovery.reveal"
        static let recoveryRecordAgainButton = "wiretap.detail.recovery.recordAgain"
        static let playbackUnavailableMessage = "wiretap.detail.player.unavailable"
        static let deleteConfirmButton = "wiretap.dialog.delete.confirm"
        static let deleteCancelButton = "wiretap.dialog.delete.cancel"
    }

    enum Onboarding {
        static let root = "wiretap.onboarding.root"
        static let systemAudioRow = "wiretap.onboarding.systemAudio"
        static let microphoneRow = "wiretap.onboarding.microphone"
        static let localFilesRow = "wiretap.onboarding.localFiles"
        static let systemAudioStatus = "wiretap.onboarding.systemAudioStatus"
        static let microphoneStatus = "wiretap.onboarding.microphoneStatus"
        static let localFilesStatus = "wiretap.onboarding.localFilesStatus"
        static let notNowButton = "wiretap.onboarding.notNow"
        static let refreshButton = "wiretap.onboarding.refresh"
        static let continueButton = "wiretap.onboarding.continue"
        static let openSettingsButton = "wiretap.onboarding.openSettings"
    }
}
