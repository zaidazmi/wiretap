import Foundation

struct CaptureModeStorage {
    private static let key = "recording.captureMode"

    private let readValue: () -> String?
    private let writeValue: (String) -> Void

    init(
        readValue: @escaping () -> String? = {
            UserDefaults.standard.string(forKey: CaptureModeStorage.key)
        },
        writeValue: @escaping (String) -> Void = { value in
            UserDefaults.standard.set(value, forKey: CaptureModeStorage.key)
        }
    ) {
        self.readValue = readValue
        self.writeValue = writeValue
    }

    func load() -> RecordingCaptureMode {
        readValue()
            .flatMap(RecordingCaptureMode.init(rawValue:))
            ?? .systemAndMicrophone
    }

    func save(_ mode: RecordingCaptureMode) {
        writeValue(mode.rawValue)
    }
}
