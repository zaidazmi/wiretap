import Foundation

enum RecordingSource: String, Codable, CaseIterable, Sendable {
    case systemAudio
    case microphone

    var label: String {
        switch self {
        case .systemAudio: "System audio"
        case .microphone: "default microphone"
        }
    }
}

struct Recording: Identifiable, Hashable, Codable, Sendable {
    enum Status: String, Codable, CaseIterable, Sendable {
        case finalized
        case recording
        case interrupted
        case missingFile

        var label: String {
            switch self {
            case .finalized: "Ready"
            case .recording: "Recording"
            case .interrupted: "Needs Review"
            case .missingFile: "Missing File"
            }
        }
    }

    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var fileURL: URL?
    var recoveryFolderURL: URL?
    var fileSizeBytes: Int64
    var sampleRate: Int
    var channelCount: Int
    var sourceSummary: String
    var status: Status

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date,
        duration: TimeInterval,
        fileURL: URL? = nil,
        recoveryFolderURL: URL? = nil,
        fileSizeBytes: Int64,
        sampleRate: Int,
        channelCount: Int,
        sourceSummary: String,
        status: Status
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.fileURL = fileURL
        self.recoveryFolderURL = recoveryFolderURL
        self.fileSizeBytes = fileSizeBytes
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.sourceSummary = sourceSummary
        self.status = status
    }

    var durationText: String {
        DurationFormatter.clock.string(from: duration)
    }

    var fileSizeText: String {
        ByteCountFormatter.string(fromByteCount: fileSizeBytes, countStyle: .file)
    }

    var fileName: String {
        fileURL?.lastPathComponent ?? recoveryFolderURL?.lastPathComponent ?? "\(title).m4a"
    }

    var folderPath: String {
        if let fileURL {
            return fileURL.deletingLastPathComponent().path
        }

        return recoveryFolderURL?.path ?? "Pending library location"
    }

    var searchableText: String {
        [
            title,
            sourceSummary,
            fileName,
            recoveryFolderURL?.path,
            status.label,
            createdAt.formatted(date: .abbreviated, time: .shortened)
        ].compactMap(\.self).joined(separator: " ")
    }

    var technicalSummary: String {
        "\(sampleRate / 1_000) kHz - \(channelCount == 1 ? "Mono" : "Stereo") - AAC"
    }

    static func sourceSummary(for sources: [RecordingSource]) -> String {
        let uniqueSources = RecordingSource.allCases.filter { sources.contains($0) }

        if uniqueSources == [.systemAudio, .microphone] {
            return "System audio + default microphone"
        }

        return uniqueSources.first?.label ?? "Recorded audio"
    }
}

extension Recording {
    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case createdAt
        case duration
        case fileURL
        case recoveryFolderURL
        case fileSizeBytes
        case sampleRate
        case channelCount
        case sourceSummary
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        fileURL = try container.decodeIfPresent(URL.self, forKey: .fileURL)
        recoveryFolderURL = try container.decodeIfPresent(URL.self, forKey: .recoveryFolderURL)
        fileSizeBytes = try container.decode(Int64.self, forKey: .fileSizeBytes)
        sampleRate = try container.decode(Int.self, forKey: .sampleRate)
        channelCount = try container.decode(Int.self, forKey: .channelCount)
        sourceSummary = try container.decode(String.self, forKey: .sourceSummary)
        status = try container.decode(Status.self, forKey: .status)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(duration, forKey: .duration)
        try container.encodeIfPresent(fileURL, forKey: .fileURL)
        try container.encodeIfPresent(recoveryFolderURL, forKey: .recoveryFolderURL)
        try container.encode(fileSizeBytes, forKey: .fileSizeBytes)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(channelCount, forKey: .channelCount)
        try container.encode(sourceSummary, forKey: .sourceSummary)
        try container.encode(status, forKey: .status)
    }
}

extension Recording {
    static let previewRecordings: [Recording] = [
        Recording(
            title: "Design Critique with Product",
            createdAt: Date().addingTimeInterval(-2_700),
            duration: 3_812,
            fileSizeBytes: 76_400_000,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System output + MacBook Pro Microphone",
            status: .finalized
        ),
        Recording(
            title: "Customer Interview - Onboarding",
            createdAt: Date().addingTimeInterval(-92_000),
            duration: 5_486,
            fileSizeBytes: 109_900_000,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System output + Studio Display Microphone",
            status: .finalized
        ),
        Recording(
            title: "Demo Audio Check",
            createdAt: Date().addingTimeInterval(-188_000),
            duration: 742,
            fileSizeBytes: 14_900_000,
            sampleRate: 48_000,
            channelCount: 2,
            sourceSummary: "System output + default microphone",
            status: .interrupted
        )
    ]
}
