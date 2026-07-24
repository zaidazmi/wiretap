import Foundation
@testable import Wiretap
import XCTest

final class AudioDeviceChangeBatcherTests: XCTestCase {
    @MainActor
    func testCoalescesRouteBurstInOutputThenInputOrder() async throws {
        let batcher = AudioDeviceChangeBatcher(delay: .milliseconds(10))
        var delivered: [AudioDeviceChange] = []
        let generation = batcher.begin { change in
            delivered.append(change)
        }

        batcher.schedule(.defaultInput, generation: generation)
        batcher.schedule(.defaultOutput, generation: generation)

        try await waitUntil { delivered.count == 2 }
        XCTAssertEqual(delivered, [.defaultOutput, .defaultInput])
        batcher.stop()
    }

    @MainActor
    func testStopSuppressesAlreadyQueuedDelivery() async throws {
        let batcher = AudioDeviceChangeBatcher(delay: .milliseconds(10))
        var delivered: [AudioDeviceChange] = []
        let generation = batcher.begin { change in
            delivered.append(change)
        }

        batcher.schedule(.defaultInput, generation: generation)
        batcher.stop()
        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(delivered.isEmpty)
    }

    @MainActor
    func testRestartRejectsPreviousGenerationCallbacks() async throws {
        let batcher = AudioDeviceChangeBatcher(delay: .milliseconds(10))
        var previousDelivered: [AudioDeviceChange] = []
        var currentDelivered: [AudioDeviceChange] = []
        let previousGeneration = batcher.begin { change in
            previousDelivered.append(change)
        }
        batcher.schedule(.defaultOutput, generation: previousGeneration)

        let currentGeneration = batcher.begin { change in
            currentDelivered.append(change)
        }
        batcher.schedule(.defaultInput, generation: previousGeneration)
        batcher.schedule(.defaultInput, generation: currentGeneration)

        try await waitUntil { currentDelivered == [.defaultInput] }
        XCTAssertTrue(previousDelivered.isEmpty)
        batcher.stop()
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for audio-device delivery")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
