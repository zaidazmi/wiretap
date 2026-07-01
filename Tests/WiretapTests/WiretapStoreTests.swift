import Foundation
@testable import Wiretap
import XCTest

final class WiretapStoreTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory,
           FileManager.default.fileExists(atPath: temporaryDirectory.path) {
            try FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    @MainActor
    func testLoadLibraryPersistsMissingFileRepair() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let missingURL = try repository.recordingURL(for: UUID())
        let recording = Recording(
            title: "Missing",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 30,
            fileURL: missingURL,
            fileSizeBytes: 2_048,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
        try repository.saveRecordings([recording])

        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        XCTAssertEqual(store.recordings.first?.status, .missingFile)
        XCTAssertEqual(try repository.loadRecordings().first?.status, .missingFile)
    }

    @MainActor
    func testLoadLibraryPersistsRecoveredActiveRecording() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let systemURL = try repository.temporarySourceURL(for: id, source: "system")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        try repository.saveRecordings([
            makeRecording(
                id: id,
                title: "Active",
                fileURL: try repository.recordingURL(for: id),
                status: .recording
            )
        ])

        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )

        store.loadLibrary()

        let recoveredRecording = try XCTUnwrap(store.recordings.first)
        let persistedRecording = try XCTUnwrap(try repository.loadRecordings().first)
        XCTAssertEqual(recoveredRecording.status, .interrupted)
        XCTAssertEqual(persistedRecording.status, .interrupted)
        XCTAssertNotNil(recoveredRecording.recoveryFolderURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testSelectedRecordingFollowsSearchFilter() {
        let designRecording = makeRecording(title: "Design Review")
        let interviewRecording = makeRecording(title: "Customer Interview")
        let store = WiretapStore(
            recordings: [designRecording, interviewRecording],
            minimumFreeDiskSpaceBytes: 0
        )
        store.select(designRecording)

        store.searchText = "Customer"

        XCTAssertEqual(store.filteredRecordings, [interviewRecording])
        XCTAssertEqual(store.selectedRecording, interviewRecording)

        store.searchText = "No Match"

        XCTAssertTrue(store.filteredRecordings.isEmpty)
        XCTAssertNil(store.selectedRecording)
    }

    @MainActor
    func testRenameSelectedPersistsTrimmedTitle() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let recording = makeRecording(title: "Original")
        try repository.saveRecordings([recording])
        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )
        store.loadLibrary()

        store.renameSelected(to: "  Renamed Recording  ")

        XCTAssertEqual(store.recordings.first?.title, "Renamed Recording")
        XCTAssertEqual(try repository.loadRecordings().first?.title, "Renamed Recording")
    }

    @MainActor
    func testDeleteSelectedPersistsLibraryAndRemovesFile() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        try Data("audio".utf8).write(to: fileURL)
        let recording = makeRecording(
            id: id,
            title: "Delete Me",
            fileURL: fileURL,
            fileSizeBytes: repository.fileSize(for: fileURL)
        )
        try repository.saveRecordings([recording])
        let store = WiretapStore(
            repository: repository,
            minimumFreeDiskSpaceBytes: 0
        )
        store.loadLibrary()

        store.deleteSelected()

        XCTAssertTrue(store.recordings.isEmpty)
        XCTAssertTrue(try repository.loadRecordings().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    private func makeRecording(
        id: UUID = UUID(),
        title: String,
        fileURL: URL? = nil,
        fileSizeBytes: Int64 = 0,
        status: Recording.Status = .finalized
    ) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 30,
            fileURL: fileURL,
            fileSizeBytes: fileSizeBytes,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: status
        )
    }
}
