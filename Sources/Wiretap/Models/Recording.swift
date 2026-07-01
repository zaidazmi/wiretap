import Foundation

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
        fileURL?.lastPathComponent ?? "\(title).m4a"
    }

    var folderPath: String {
        fileURL?.deletingLastPathComponent().path ?? "Pending library location"
    }

    var searchableText: String {
        [
            title,
            sourceSummary,
            fileName,
            status.label,
            createdAt.formatted(date: .abbreviated, time: .shortened)
        ].joined(separator: " ")
    }

    var technicalSummary: String {
        "\(sampleRate / 1_000) kHz - \(channelCount == 1 ? "Mono" : "Stereo") - AAC"
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
