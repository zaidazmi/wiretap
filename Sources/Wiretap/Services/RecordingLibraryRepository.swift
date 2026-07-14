import Foundation
import SwiftData

struct RecordingLibraryRepository {
    let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        appDirectoryName: String = Bundle.main.bundleIdentifier ?? "dev.zaidazmi.Wiretap",
        applicationSupportDirectory: URL? = nil
    ) {
        if let applicationSupportDirectory {
            self.applicationSupportDirectory = applicationSupportDirectory
        } else {
            let baseURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.applicationSupportDirectory = baseURL.appendingPathComponent(appDirectoryName, isDirectory: true)
        }
    }

    var recordingsDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    }

    var recoveryDirectory: URL {
        applicationSupportDirectory.appendingPathComponent("Recovery", isDirectory: true)
    }

    var swiftDataStoreURL: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings.store")
    }

    private var legacyMetadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings.json")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: recoveryDirectory,
            withIntermediateDirectories: true
        )
    }

    func availableCapacityForRecordings() throws -> Int64 {
        try prepare()
        let values = try recordingsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values.volumeAvailableCapacityForImportantUsage ?? 0
    }

    func ensureSufficientDiskSpace(minimumBytes: Int64) throws {
        let availableBytes = try availableCapacityForRecordings()
        guard availableBytes >= minimumBytes else {
            throw RecordingLibraryError.insufficientDiskSpace(available: availableBytes, required: minimumBytes)
        }
    }

    func loadRecordings() throws -> [Recording] {
        try prepare()

        let context = try makeModelContext()
        let descriptor = FetchDescriptor<RecordingRecord>(
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        let records = try context.fetch(descriptor)
        if records.isEmpty {
            let legacyRecordings = try loadLegacyRecordingsIfPresent()
            if !legacyRecordings.isEmpty {
                try saveRecordings(legacyRecordings)
            }
            return legacyRecordings
        }

        return records.map { $0.recording(baseDirectory: applicationSupportDirectory) }
    }

    func refreshedFileStatuses(for recordings: [Recording]) -> [Recording] {
        recordings.map { recording in
            var refreshed = recording

            switch recording.status {
            case .finalized:
                guard let fileURL = recording.fileURL,
                      FileManager.default.fileExists(atPath: fileURL.path)
                else {
                    refreshed.status = .missingFile
                    refreshed.fileSizeBytes = 0
                    return refreshed
                }

                refreshed.fileSizeBytes = fileSize(for: fileURL)

            case .missingFile:
                if let fileURL = recording.fileURL,
                   FileManager.default.fileExists(atPath: fileURL.path) {
                    refreshed.status = .finalized
                    refreshed.fileSizeBytes = fileSize(for: fileURL)
                }

            case .recording, .processing:
                if let fileURL = recording.fileURL,
                   FileManager.default.fileExists(atPath: fileURL.path) {
                    refreshed.status = .finalized
                    refreshed.fileSizeBytes = fileSize(for: fileURL)
                    return refreshed
                }

                let recoveryFolderURL = existingRecoveryFolderIfPresent(for: recording.id)
                    ?? (try? retainTemporaryFiles(
                        temporarySourceURLs(for: recording.id),
                        for: recording.id
                    ))
                refreshed.status = .interrupted
                refreshed.fileURL = nil
                refreshed.recoveryFolderURL = recoveryFolderURL
                refreshed.fileSizeBytes = 0
                refreshed.duration = max(recording.duration, 1)
                refreshed.sourceSummary = recoveryFolderURL == nil
                    ? "Interrupted - recording could not be recovered"
                    : RecordingInterruptionReason.unexpectedShutdown.recoverySummary

            case .interrupted:
                if refreshed.recoveryFolderURL == nil,
                   let recoveryFolderURL = existingRecoveryFolderIfPresent(for: recording.id) {
                    refreshed.recoveryFolderURL = recoveryFolderURL
                    refreshed.sourceSummary = RecordingInterruptionReason.unexpectedShutdown.recoverySummary
                }
                break
            }

            return refreshed
        }
    }

    func saveRecordings(_ recordings: [Recording]) throws {
        try prepare()

        let context = try makeModelContext()
        let existingRecords = try context.fetch(FetchDescriptor<RecordingRecord>())
        var incomingByID: [Recording.ID: Recording] = [:]
        for recording in recordings {
            incomingByID[recording.id] = recording
        }

        var existingIDs = Set<Recording.ID>()
        for record in existingRecords {
            existingIDs.insert(record.id)
            if let recording = incomingByID[record.id] {
                record.update(from: recording, baseDirectory: applicationSupportDirectory)
            } else {
                context.delete(record)
            }
        }

        for recording in recordings where !existingIDs.contains(recording.id) {
            context.insert(RecordingRecord(recording: recording, baseDirectory: applicationSupportDirectory))
        }

        try context.save()
    }

    func recordingURL(for id: Recording.ID) throws -> URL {
        try prepare()
        return recordingsDirectory
            .appendingPathComponent(id.uuidString, isDirectory: false)
            .appendingPathExtension("m4a")
    }

    func temporarySourceURL(for id: Recording.ID, source: String) throws -> URL {
        try prepare()
        return recordingsDirectory
            .appendingPathComponent("\(id.uuidString)-\(source)", isDirectory: false)
            .appendingPathExtension("caf")
    }

    func recoveryURL(for id: Recording.ID) throws -> URL {
        try prepare()
        return recoveryDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func fileSize(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func deleteFileIfPresent(for recording: Recording) throws {
        let urls = [recording.fileURL, recording.recoveryFolderURL].compactMap(\.self)

        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func copyRecording(_ recording: Recording, to destinationURL: URL) throws {
        guard let sourceURL = recording.fileURL,
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            throw RecordingLibraryError.missingFile
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
    }

    func deleteTemporaryFiles(_ urls: [URL]) {
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func retainTemporaryFiles(_ urls: [URL], for id: Recording.ID) throws -> URL? {
        let recoveryURL = try recoveryURL(for: id)
        try FileManager.default.createDirectory(
            at: recoveryURL,
            withIntermediateDirectories: true
        )

        var didRetainFile = false
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            let destinationURL = recoveryURL.appendingPathComponent(url.lastPathComponent)
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.moveItem(at: url, to: destinationURL)
            didRetainFile = true
        }

        if didRetainFile {
            return recoveryURL
        }

        try? FileManager.default.removeItem(at: recoveryURL)
        return nil
    }

    private func temporarySourceURLs(for id: Recording.ID) -> [URL] {
        ["system", "microphone"].flatMap { source in
            [
                try? temporarySourceURL(for: id, source: source),
                recordingsDirectory
                    .appendingPathComponent("\(id.uuidString)-\(source)", isDirectory: false)
                    .appendingPathExtension("m4a")
            ].compactMap(\.self)
        }
    }

    private func existingRecoveryFolderIfPresent(for id: Recording.ID) -> URL? {
        guard let recoveryURL = try? recoveryURL(for: id),
              FileManager.default.fileExists(atPath: recoveryURL.path),
              let contents = try? FileManager.default.contentsOfDirectory(
                at: recoveryURL,
                includingPropertiesForKeys: nil
              ),
              !contents.isEmpty
        else {
            return nil
        }

        return recoveryURL
    }

    private func makeModelContext() throws -> ModelContext {
        let schema = Schema([RecordingRecord.self])
        let configuration = ModelConfiguration(
            "WiretapLibrary",
            schema: schema,
            url: swiftDataStoreURL,
            cloudKitDatabase: .none
        )
        return try ModelContext(ModelContainer(for: schema, configurations: [configuration]))
    }

    private func loadLegacyRecordingsIfPresent() throws -> [Recording] {
        guard FileManager.default.fileExists(atPath: legacyMetadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: legacyMetadataURL)
        let recordings = try JSONDecoder.wiretap.decode([Recording].self, from: data)
        return recordings.sorted { $0.createdAt > $1.createdAt }
    }
}

enum RecordingLibraryError: LocalizedError {
    case missingFile
    case insufficientDiskSpace(available: Int64, required: Int64)

    var errorDescription: String? {
        switch self {
        case .missingFile:
            return "The audio file for this recording could not be found."
        case let .insufficientDiskSpace(available, required):
            let availableText = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            let requiredText = ByteCountFormatter.string(fromByteCount: required, countStyle: .file)
            return "Wiretap needs at least \(requiredText) free for a safe recording session. Available: \(availableText)."
        }
    }
}

private extension JSONDecoder {
    static var wiretap: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
