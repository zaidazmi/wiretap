import AVFoundation
import Foundation
import SwiftData
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
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.swiftDataStoreURL.path))
    }

    func testRecordingRecordStoresManagedLibraryPathsRelatively() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        let recoveryURL = try repository.recoveryURL(for: id)
        let recording = Recording(
            id: id,
            title: "Relative",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 1,
            fileURL: fileURL,
            recoveryFolderURL: recoveryURL,
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )

        let record = RecordingRecord(recording: recording, baseDirectory: temporaryDirectory)

        XCTAssertEqual(record.filePath, "Recordings/\(id.uuidString).m4a")
        XCTAssertEqual(record.recoveryFolderPath, "Recovery/\(id.uuidString)")
        XCTAssertEqual(record.recording(baseDirectory: temporaryDirectory), recording)
    }

    func testTemporarySourceURLUsesLosslessCaptureContainer() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()

        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")

        XCTAssertEqual(microphoneURL.pathExtension, "caf")
        XCTAssertEqual(microphoneURL.lastPathComponent, "\(id.uuidString)-microphone.caf")
    }

    func testLegacyJSONMetadataImportsIntoSwiftDataStore() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let fileURL = try repository.recordingURL(for: id)
        let recording = Recording(
            id: id,
            title: "Legacy",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 42,
            fileURL: fileURL,
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
        let legacyURL = temporaryDirectory.appendingPathComponent("Recordings.json")
        let data = try JSONEncoder.wiretapTest.encode([recording])
        try data.write(to: legacyURL)

        XCTAssertEqual(try repository.loadRecordings(), [recording])
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.swiftDataStoreURL.path))

        try FileManager.default.removeItem(at: legacyURL)

        XCTAssertEqual(try repository.loadRecordings(), [recording])
    }

    func testSaveRecordingsUpdatesAndDeletesSwiftDataRows() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let firstID = UUID()
        let secondID = UUID()
        let first = Recording(
            id: firstID,
            title: "First",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 12,
            fileURL: try repository.recordingURL(for: firstID),
            fileSizeBytes: 1_024,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
        let second = Recording(
            id: secondID,
            title: "Second",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 24,
            fileURL: try repository.recordingURL(for: secondID),
            fileSizeBytes: 2_048,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )
        var renamedFirst = first
        renamedFirst.title = "Renamed First"

        try repository.saveRecordings([first, second])
        try repository.saveRecordings([renamedFirst])

        XCTAssertEqual(try repository.loadRecordings(), [renamedFirst])
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

    func testCopyRecordingThrowsWhenSourceFileIsMissing() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let fileURL = try repository.recordingURL(for: UUID())
        let recording = Recording(
            title: "Missing File",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 1,
            fileURL: fileURL,
            fileSizeBytes: 2_048,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Default microphone",
            status: .finalized
        )
        let destinationURL = temporaryDirectory.appendingPathComponent("Exported.m4a")

        XCTAssertThrowsError(try repository.copyRecording(recording, to: destinationURL)) { error in
            guard case RecordingLibraryError.missingFile = error else {
                XCTFail("Expected missing file error, got \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationURL.path))
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

    func testRefreshedFileStatusesMarksMissingFinalizedFiles() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let fileURL = try repository.recordingURL(for: UUID())
        let recording = Recording(
            title: "Missing",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 8,
            fileURL: fileURL,
            fileSizeBytes: 2_048,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .finalized
        )

        let refreshed = repository.refreshedFileStatuses(for: [recording])

        XCTAssertEqual(refreshed.first?.status, .missingFile)
        XCTAssertEqual(refreshed.first?.fileSizeBytes, 0)
    }

    func testRefreshedFileStatusesRestoresFoundMissingFilesAndInterruptsActiveRows() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let restoredURL = try repository.recordingURL(for: UUID())
        try writeAudio(to: restoredURL, duration: 0.2)
        let missingRecording = Recording(
            title: "Restored",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 0.2,
            fileURL: restoredURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .missingFile
        )
        let activeRecording = Recording(
            title: "Interrupted",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 8,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .recording
        )

        let refreshed = repository.refreshedFileStatuses(for: [missingRecording, activeRecording])

        XCTAssertEqual(refreshed[0].status, .finalized)
        XCTAssertEqual(refreshed[0].fileSizeBytes, repository.fileSize(for: restoredURL))
        XCTAssertEqual(refreshed[1].status, .interrupted)
    }

    func testRefreshedFileStatusesFinalizesActiveRowWhenOutputExists() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        try writeAudio(to: finalURL, duration: 0.2)
        let activeRecording = Recording(
            id: id,
            title: "Active",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 0.2,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .recording
        )

        let refreshed = repository.refreshedFileStatuses(for: [activeRecording])

        XCTAssertEqual(refreshed.first?.status, .finalized)
        XCTAssertEqual(refreshed.first?.fileSizeBytes, repository.fileSize(for: finalURL))
    }

    func testRefreshedFileStatusesRecoversProcessingRowAfterRelaunch() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let systemURL = try repository.temporarySourceURL(for: id, source: "system")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        let processingRecording = Recording(
            id: id,
            title: "Processing",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 120,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .processing
        )

        let refreshed = repository.refreshedFileStatuses(for: [processingRecording])

        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertNil(refreshed.first?.fileURL)
        XCTAssertNotNil(refreshed.first?.recoveryFolderURL)
        XCTAssertEqual(
            refreshed.first?.sourceSummary,
            RecordingInterruptionReason.unexpectedShutdown.recoverySummary
        )
    }

    func testRefreshedFileStatusesRetainsIncompleteMixedOutputAfterCrash() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        try writeAudio(to: finalURL, duration: 0.2)
        try Data("mic".utf8).write(to: microphoneURL)
        let processingRecording = Recording(
            id: id,
            title: "Processing",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 120,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .processing
        )

        let refreshed = repository.refreshedFileStatuses(for: [processingRecording])

        let recoveryURL = try XCTUnwrap(refreshed.first?.recoveryFolderURL)
        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertNil(refreshed.first?.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: finalURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryURL.appendingPathComponent(finalURL.lastPathComponent).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryURL.appendingPathComponent(microphoneURL.lastPathComponent).path
        ))
    }

    func testRefreshedFileStatusesRetainsActiveRecordingSourceFiles() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let systemURL = try repository.temporarySourceURL(for: id, source: "system")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)
        let activeRecording = Recording(
            id: id,
            title: "Active",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 0,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .recording
        )

        let refreshed = repository.refreshedFileStatuses(for: [activeRecording])
        let recoveryFolderURL = try XCTUnwrap(refreshed.first?.recoveryFolderURL)

        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertNil(refreshed.first?.fileURL)
        XCTAssertEqual(
            refreshed.first?.sourceSummary,
            RecordingInterruptionReason.unexpectedShutdown.recoverySummary
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryFolderURL.appendingPathComponent(microphoneURL.lastPathComponent).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryFolderURL.appendingPathComponent(systemURL.lastPathComponent).path
        ))
    }

    func testRefreshedFileStatusesRecoversExistingFolderForActiveRow() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        let recoveryURL = try repository.recoveryURL(for: id)
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        let retainedSourceURL = recoveryURL.appendingPathComponent("\(id.uuidString)-microphone.m4a")
        try Data("retained mic".utf8).write(to: retainedSourceURL)
        let activeRecording = Recording(
            id: id,
            title: "Active",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 0,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .recording
        )

        let refreshed = repository.refreshedFileStatuses(for: [activeRecording])

        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertNil(refreshed.first?.fileURL)
        XCTAssertEqual(refreshed.first?.recoveryFolderURL, recoveryURL)
        XCTAssertEqual(
            refreshed.first?.sourceSummary,
            RecordingInterruptionReason.unexpectedShutdown.recoverySummary
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSourceURL.path))
    }

    func testRefreshedFileStatusesCompletesPartiallyInterruptedRecoveryMove() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let finalURL = try repository.recordingURL(for: id)
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let recoveryURL = try repository.recoveryURL(for: id)
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        let retainedSystemURL = recoveryURL
            .appendingPathComponent("\(id.uuidString)-system.caf")
        try Data("retained system".utf8).write(to: retainedSystemURL)
        try Data("remaining microphone".utf8).write(to: microphoneURL)
        let activeRecording = Recording(
            id: id,
            title: "Partially Recovered",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 12,
            fileURL: finalURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System audio + default microphone",
            status: .processing
        )

        let refreshed = repository.refreshedFileStatuses(for: [activeRecording])

        let retainedMicrophoneURL = recoveryURL
            .appendingPathComponent(microphoneURL.lastPathComponent)
        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertEqual(refreshed.first?.recoveryFolderURL, recoveryURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedSystemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: retainedMicrophoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
    }

    func testRefreshedFileStatusesRestoresExistingFolderForInterruptedRow() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let recoveryURL = try repository.recoveryURL(for: id)
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )
        try Data("retained system".utf8).write(
            to: recoveryURL.appendingPathComponent("\(id.uuidString)-system.m4a")
        )
        let interruptedRecording = Recording(
            id: id,
            title: "Interrupted",
            createdAt: Date(timeIntervalSince1970: 1_782_900_100),
            duration: 4,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Interrupted - recording could not be recovered",
            status: .interrupted
        )

        let refreshed = repository.refreshedFileStatuses(for: [interruptedRecording])

        XCTAssertEqual(refreshed.first?.status, .interrupted)
        XCTAssertEqual(refreshed.first?.recoveryFolderURL, recoveryURL)
        XCTAssertEqual(
            refreshed.first?.sourceSummary,
            RecordingInterruptionReason.unexpectedShutdown.recoverySummary
        )
    }

    func testRetainTemporaryFilesMovesSourcesAndDeleteRemovesRecoveryFolder() throws {
        let repository = RecordingLibraryRepository(applicationSupportDirectory: temporaryDirectory)
        let id = UUID()
        let microphoneURL = try repository.temporarySourceURL(for: id, source: "microphone")
        let systemURL = try repository.temporarySourceURL(for: id, source: "system")
        try Data("mic".utf8).write(to: microphoneURL)
        try Data("system".utf8).write(to: systemURL)

        let recoveryURL = try XCTUnwrap(repository.retainTemporaryFiles([microphoneURL, systemURL], for: id))

        XCTAssertFalse(FileManager.default.fileExists(atPath: microphoneURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryURL.appendingPathComponent(microphoneURL.lastPathComponent).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: recoveryURL.appendingPathComponent(systemURL.lastPathComponent).path
        ))

        let recording = Recording(
            id: id,
            title: "Recovery",
            createdAt: Date(timeIntervalSince1970: 1_782_900_000),
            duration: 8,
            recoveryFolderURL: recoveryURL,
            fileSizeBytes: 0,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "Recording sources retained for recovery",
            status: .interrupted
        )

        try repository.deleteFileIfPresent(for: recording)

        XCTAssertFalse(FileManager.default.fileExists(atPath: recoveryURL.path))
    }

    private func writeAudio(to url: URL, duration: TimeInterval) throws {
        let sampleRate = 48_000.0
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            XCTFail("Could not create repository test audio format")
            return
        }
        let frameCount = AVAudioFrameCount((duration * sampleRate).rounded())
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: frameCount
        ), let channels = buffer.floatChannelData else {
            XCTFail("Could not create repository test audio buffer")
            return
        }
        buffer.frameLength = frameCount

        for frame in 0..<Int(frameCount) {
            let sample = Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate) * 0.1)
            channels[0][frame] = sample
            channels[1][frame] = sample
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]
        )
        try file.write(from: buffer)
    }
}

private extension JSONEncoder {
    static var wiretapTest: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
