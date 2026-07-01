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
}
