import Foundation

@MainActor
final class RecordingTimelineTicker {
    private var task: Task<Void, Never>?

    init(store: WiretapStore) {
        task = Task { @MainActor [weak store] in
            while !Task.isCancelled {
                if let store, store.isTimelineActive {
                    store.tick()
                }

                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    deinit {
        task?.cancel()
    }
}
