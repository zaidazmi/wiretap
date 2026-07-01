import Foundation
import SwiftData

@Model
final class RecordingRecord {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var filePath: String?
    var recoveryFolderPath: String?
    var fileSizeBytes: Int64
    var sampleRate: Int
    var channelCount: Int
    var sourceSummary: String
    var statusRawValue: String

    init(recording: Recording, baseDirectory: URL) {
        id = recording.id
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        filePath = Self.storedPath(for: recording.fileURL, baseDirectory: baseDirectory)
        recoveryFolderPath = Self.storedPath(for: recording.recoveryFolderURL, baseDirectory: baseDirectory)
        fileSizeBytes = recording.fileSizeBytes
        sampleRate = recording.sampleRate
        channelCount = recording.channelCount
        sourceSummary = recording.sourceSummary
        statusRawValue = recording.status.rawValue
    }

    func update(from recording: Recording, baseDirectory: URL) {
        title = recording.title
        createdAt = recording.createdAt
        duration = recording.duration
        filePath = Self.storedPath(for: recording.fileURL, baseDirectory: baseDirectory)
        recoveryFolderPath = Self.storedPath(for: recording.recoveryFolderURL, baseDirectory: baseDirectory)
        fileSizeBytes = recording.fileSizeBytes
        sampleRate = recording.sampleRate
        channelCount = recording.channelCount
        sourceSummary = recording.sourceSummary
        statusRawValue = recording.status.rawValue
    }

    func recording(baseDirectory: URL) -> Recording {
        Recording(
            id: id,
            title: title,
            createdAt: createdAt,
            duration: duration,
            fileURL: Self.resolvedURL(for: filePath, baseDirectory: baseDirectory),
            recoveryFolderURL: Self.resolvedURL(
                for: recoveryFolderPath,
                baseDirectory: baseDirectory,
                isDirectory: true
            ),
            fileSizeBytes: fileSizeBytes,
            sampleRate: sampleRate,
            channelCount: channelCount,
            sourceSummary: sourceSummary,
            status: Recording.Status(rawValue: statusRawValue) ?? .interrupted
        )
    }

    private static func storedPath(for url: URL?, baseDirectory: URL) -> String? {
        guard let url else { return nil }

        let basePath = baseDirectory.standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        if candidatePath == basePath {
            return "."
        }

        let prefix = basePath.hasSuffix("/") ? basePath : basePath + "/"
        guard candidatePath.hasPrefix(prefix) else {
            return candidatePath
        }

        return String(candidatePath.dropFirst(prefix.count))
    }

    private static func resolvedURL(
        for storedPath: String?,
        baseDirectory: URL,
        isDirectory: Bool = false
    ) -> URL? {
        guard let storedPath else { return nil }

        if storedPath == "." {
            return baseDirectory
        }

        if storedPath.hasPrefix("/") {
            return URL(fileURLWithPath: storedPath, isDirectory: isDirectory)
        }

        return baseDirectory.appendingPathComponent(storedPath, isDirectory: isDirectory)
    }
}
