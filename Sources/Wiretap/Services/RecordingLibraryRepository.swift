import Foundation

struct RecordingLibraryRepository {
    let applicationSupportDirectory: URL

    init(
        fileManager: FileManager = .default,
        appDirectoryName: String = "Wiretap",
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

    private var metadataURL: URL {
        applicationSupportDirectory.appendingPathComponent("Recordings.json")
    }

    func prepare() throws {
        try FileManager.default.createDirectory(
            at: recordingsDirectory,
            withIntermediateDirectories: true
        )
    }

    func loadRecordings() throws -> [Recording] {
        try prepare()

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            return []
        }

        let data = try Data(contentsOf: metadataURL)
        let recordings = try JSONDecoder.wiretap.decode([Recording].self, from: data)

        return recordings.sorted { $0.createdAt > $1.createdAt }
    }

    func saveRecordings(_ recordings: [Recording]) throws {
        try prepare()
        let data = try JSONEncoder.wiretap.encode(recordings)
        try data.write(to: metadataURL, options: [.atomic])
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
            .appendingPathExtension("m4a")
    }

    func fileSize(for url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values?.fileSize ?? 0)
    }

    func deleteFileIfPresent(for recording: Recording) throws {
        guard let fileURL = recording.fileURL,
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return }

        try FileManager.default.removeItem(at: fileURL)
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
}

enum RecordingLibraryError: LocalizedError {
    case missingFile

    var errorDescription: String? {
        switch self {
        case .missingFile:
            "The audio file for this recording could not be found."
        }
    }
}

private extension JSONEncoder {
    static var wiretap: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var wiretap: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
