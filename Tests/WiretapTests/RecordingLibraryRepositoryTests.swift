import Foundation
@testable import Wiretap
import XCTest

final class RecordingLibraryRepositoryTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WiretapTests-\(UUID().uuidString)", isDirectory: true)
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

    func testSaveAndLoadRecordingsRoundTripsMetadata() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let fileURL = try repository.recordingURL(for: UUID())
        let recording = Recording(
            title: "Round Trip",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 42,
            fileURL: fileURL,
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )

        try repository.saveRecordings([recording])

        let loaded = try repository.loadRecordings()
        XCTAssertEqual(loaded, [recording])
    }

    func testCopyAndDeleteRecordingFile() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let fileURL = try repository.recordingURL(for: UUID())
        try Data("audio".utf8).write(to: fileURL)
        let recording = Recording(
            title: "File",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 1,
            fileURL: fileURL,
            fileSizeBytes: repository.fileSize(for: fileURL),
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Default microphone",
            status: .finalized
        )
        let destinationURL = temporaryDirectory.appendingPathComponent("Exported.m4a")

        try repository.copyRecording(recording, to: destinationURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destinationURL.path))

        try repository.deleteFileIfPresent(for: recording)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testDiskSpacePreflightThrowsWhenRequirementIsTooLarge() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)

        XCTAssertThrowsError(
            try repository.ensureSufficientDiskSpace(minimumBytes: Int64.max)
        ) { error in
            guard case RecordingLibraryError.insufficientDiskSpace = error else {
                XCTFail("Expected insufficient disk space error, got \(error)")
                return
            }
        }
    }
}
