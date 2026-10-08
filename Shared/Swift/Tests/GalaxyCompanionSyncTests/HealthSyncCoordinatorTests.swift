import Foundation
import XCTest
@testable import GalaxyCompanionProtocol
@testable import GalaxyCompanionSimulator
@testable import GalaxyCompanionSync

final class HealthSyncCoordinatorTests: XCTestCase {
    func testSynchronizePersistsOnlyNewSamplesAcrossReconnect() async throws {
        let watch = FakeWatchSyncSource(
            capabilities: WatchCapabilities(
                identity: WatchIdentity(
                    model: "Galaxy Watch Test",
                    wearOSVersion: "5.0",
                    firmwareVersion: "test-1"
                ),
                enabled: [.heartRate, .steps]
            ),
            samples: [
                sample(id: "00000000-0000-0000-0000-000000000001", metric: .steps, value: 120),
                sample(id: "00000000-0000-0000-0000-000000000002", metric: .heartRate, value: 62)
            ]
        )
        let store = InMemoryHealthSampleStore()
        let coordinator = HealthSyncCoordinator(source: watch, store: store)

        let firstReceipt = try await coordinator.synchronize()
        let reconnectReceipt = try await coordinator.synchronize()
        let persistedSamples = await store.allSamples()

        XCTAssertEqual(firstReceipt.insertedSampleCount, 2)
        XCTAssertEqual(firstReceipt.duplicateSampleCount, 0)
        XCTAssertEqual(firstReceipt.cursor, 2)
        XCTAssertEqual(reconnectReceipt.insertedSampleCount, 0)
        XCTAssertEqual(reconnectReceipt.cursor, 2)
        XCTAssertEqual(persistedSamples.count, 2)
    }

    func testStoreDeduplicatesRetriedBatch() async throws {
        let store = InMemoryHealthSampleStore()
        let batch = HealthSyncBatch(
            sequence: 4,
            nextCursor: 1,
            samples: [sample(id: "00000000-0000-0000-0000-000000000003", metric: .steps, value: 500)]
        )

        let initial = try await store.persist(batch)
        let retry = try await store.persist(batch)
        let cursor = await store.currentCursor()

        XCTAssertEqual(initial.insertedSampleCount, 1)
        XCTAssertEqual(retry.insertedSampleCount, 0)
        XCTAssertEqual(retry.duplicateSampleCount, 1)
        XCTAssertEqual(cursor, 1)
    }

    func testRejectsInvalidBatchLimit() async {
        let watch = FakeWatchSyncSource(
            capabilities: WatchCapabilities(
                identity: WatchIdentity(model: "Test", wearOSVersion: "5", firmwareVersion: "1"),
                enabled: []
            )
        )
        let coordinator = HealthSyncCoordinator(source: watch, store: InMemoryHealthSampleStore())

        do {
            _ = try await coordinator.synchronize(maximumSampleCount: 0)
            XCTFail("Expected invalid batch limit")
        } catch let error as SynchronizationError {
            XCTAssertEqual(error, .invalidBatchLimit)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func sample(id: String, metric: HealthMetric, value: Double) -> HealthSample {
        HealthSample(
            id: UUID(uuidString: id)!,
            metric: metric,
            value: value,
            unit: metric == .heartRate ? .beatsPerMinute : .count,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            source: .wearHealthServices,
            quality: .measured
        )
    }
}
