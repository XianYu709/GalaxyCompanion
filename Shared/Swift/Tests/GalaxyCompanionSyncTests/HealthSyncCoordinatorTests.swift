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

    func testStoreReplacesCorrectedSampleWithNewerRevision() async throws {
        let store = InMemoryHealthSampleStore()
        let id = "00000000-0000-0000-0000-000000000009"
        let original = sample(id: id, metric: .steps, value: 500, revision: 3)
        _ = try await store.persist(
            HealthSyncBatch(sequence: 1, nextCursor: 3, samples: [original])
        )

        let corrected = sample(id: id, metric: .steps, value: 520, revision: 4)
        let receipt = try await store.persist(
            HealthSyncBatch(sequence: 2, nextCursor: 4, samples: [corrected])
        )
        let samples = await store.allSamples()

        XCTAssertEqual(receipt.insertedSampleCount, 0)
        XCTAssertEqual(receipt.updatedSampleCount, 1)
        XCTAssertEqual(receipt.duplicateSampleCount, 0)
        XCTAssertEqual(samples, [corrected])
    }

    func testInMemoryStoreLeavesPageUnchangedWhenLaterCorrectionConflicts() async throws {
        let store = InMemoryHealthSampleStore()
        let existingID = "00000000-0000-0000-0000-000000000011"
        let existing = sample(id: existingID, metric: .steps, value: 100, revision: 2)
        _ = try await store.persist(
            HealthSyncBatch(sequence: 1, nextCursor: 2, samples: [existing])
        )

        let newID = "00000000-0000-0000-0000-000000000012"
        let conflicting = sample(id: existingID, metric: .steps, value: 101, revision: 2)
        let invalidPage = HealthSyncBatch(
            sequence: 2,
            nextCursor: 4,
            samples: [sample(id: newID, metric: .steps, value: 5), conflicting]
        )

        do {
            _ = try await store.persist(invalidPage)
            XCTFail("Expected same-revision conflict")
        } catch let error as SynchronizationError {
            XCTAssertEqual(error, .conflictingSampleRevision(existing.id))
        }

        let cursorAfterFailure = await store.currentCursor()
        let samplesAfterFailure = await store.allSamples()
        XCTAssertEqual(cursorAfterFailure, 2)
        XCTAssertEqual(samplesAfterFailure, [existing])
    }

    func testValidatorRejectsExplicitRetentionGap() {
        let batch = HealthSyncBatch(
            sequence: 5,
            nextCursor: 3,
            samples: [],
            failure: HealthSyncRemoteError(
                code: .retentionGap,
                earliestAvailableCursor: 12
            )
        )

        XCTAssertThrowsError(try HealthSyncBatchValidator.validate(batch, after: 3)) {
            XCTAssertEqual($0 as? SynchronizationError, .remoteFailure(.retentionGap))
        }
    }

    func testValidatorRejectsRetentionGapThatTriesToAdvanceCursor() {
        let batch = HealthSyncBatch(
            sequence: 5,
            nextCursor: 4,
            samples: [],
            failure: HealthSyncRemoteError(
                code: .retentionGap,
                earliestAvailableCursor: 12
            )
        )

        XCTAssertThrowsError(try HealthSyncBatchValidator.validate(batch, after: 3)) {
            XCTAssertEqual($0 as? SynchronizationError, .malformedRemoteFailure)
        }
    }

    func testCoordinatorDrainsAllAvailablePages() async throws {
        let samples = (1...25).map { index in
            sample(
                id: String(format: "00000000-0000-0000-0000-%012d", index),
                metric: .steps,
                value: Double(index)
            )
        }
        let watch = FakeWatchSyncSource(
            capabilities: WatchCapabilities(
                identity: WatchIdentity(model: "Test", wearOSVersion: "5", firmwareVersion: "1"),
                enabled: [.steps]
            ),
            samples: samples
        )
        let store = InMemoryHealthSampleStore()

        let receipt = try await HealthSyncCoordinator(source: watch, store: store).synchronize()
        let persisted = await store.allSamples()

        XCTAssertEqual(receipt.insertedSampleCount, 25)
        XCTAssertEqual(receipt.cursor, 25)
        XCTAssertEqual(persisted.count, 25)
    }

    func testCoordinatorDrainsFullRetentionRangeWhenMTUAllowsOneSamplePages() async throws {
        let samples = (1...2_000).map { index in
            sample(
                id: String(format: "00000000-0000-0000-0000-%012d", index + 100),
                metric: .steps,
                value: Double(index)
            )
        }
        let watch = FakeWatchSyncSource(
            capabilities: WatchCapabilities(
                identity: WatchIdentity(model: "Test", wearOSVersion: "5", firmwareVersion: "1"),
                enabled: [.steps]
            ),
            samples: samples
        )
        let store = InMemoryHealthSampleStore()

        let receipt = try await HealthSyncCoordinator(source: watch, store: store)
            .synchronize(maximumSampleCount: 1)

        XCTAssertEqual(receipt.insertedSampleCount, 2_000)
        XCTAssertEqual(receipt.cursor, 2_000)
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

    func testFileStorePersistsCursorAndDeduplicatesAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyCompanionFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("health-sync.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let initialStore = try FileHealthSampleStore(fileURL: fileURL)
        let batch = HealthSyncBatch(
            sequence: 1,
            nextCursor: 1,
            samples: [sample(id: "00000000-0000-0000-0000-000000000004", metric: .steps, value: 800)]
        )
        _ = try await initialStore.persist(batch)

        let restoredStore = try FileHealthSampleStore(fileURL: fileURL)
        let retryReceipt = try await restoredStore.persist(batch)
        let restoredCursor = await restoredStore.currentCursor()
        let restoredSamples = await restoredStore.allSamples()

        XCTAssertEqual(restoredCursor, 1)
        XCTAssertEqual(restoredSamples.count, 1)
        XCTAssertEqual(retryReceipt.insertedSampleCount, 0)
        XCTAssertEqual(retryReceipt.duplicateSampleCount, 1)
    }

    func testFileStorePersistsCorrectedRevisionAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyCompanionCorrectionStoreTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("health-sync.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let id = "00000000-0000-0000-0000-000000000010"
        let original = sample(id: id, metric: .steps, value: 100, revision: 2)
        let firstStore = try FileHealthSampleStore(fileURL: fileURL)
        _ = try await firstStore.persist(
            HealthSyncBatch(sequence: 1, nextCursor: 2, samples: [original])
        )

        let corrected = sample(id: id, metric: .steps, value: 110, revision: 3)
        let restoredStore = try FileHealthSampleStore(fileURL: fileURL)
        let receipt = try await restoredStore.persist(
            HealthSyncBatch(sequence: 2, nextCursor: 3, samples: [corrected])
        )
        let restoredSamples = await restoredStore.allSamples()

        XCTAssertEqual(receipt.updatedSampleCount, 1)
        XCTAssertEqual(restoredSamples, [corrected])
    }

    func testConfirmedRetentionRecoveryAdvancesOnlyTheDurableCursor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyCompanionRetentionRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("health-sync.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let firstStore = try FileHealthSampleStore(fileURL: fileURL)
        let existing = sample(
            id: "00000000-0000-0000-0000-000000000013",
            metric: .steps,
            value: 321
        )
        _ = try await firstStore.persist(
            HealthSyncBatch(sequence: 1, nextCursor: 3, samples: [existing])
        )

        try await firstStore.advanceCursorForConfirmedRetentionRecovery(to: 12)

        let restoredStore = try FileHealthSampleStore(fileURL: fileURL)
        let restoredCursor = await restoredStore.currentCursor()
        let restoredSamples = await restoredStore.allSamples()
        XCTAssertEqual(restoredCursor, 12)
        XCTAssertEqual(restoredSamples, [existing])

        do {
            try await restoredStore.advanceCursorForConfirmedRetentionRecovery(to: 11)
            XCTFail("A recovery confirmation must never move the cursor backward")
        } catch let error as SynchronizationError {
            XCTAssertEqual(error, .regressiveCursor(received: 11, current: 12))
        }
    }

    func testStoreRejectsUnsupportedBatchVersion() async throws {
        let store = InMemoryHealthSampleStore()
        let incompatibleBatch = HealthSyncBatch(
            protocolVersion: 2,
            sequence: 1,
            nextCursor: 0,
            samples: []
        )

        do {
            _ = try await store.persist(incompatibleBatch)
            XCTFail("Expected incompatible protocol version")
        } catch let error as SynchronizationError {
            XCTAssertEqual(error, .incompatibleProtocolVersion(2))
        }
    }

    func testDecodesVersionedBatchPayloadServedByWatchWireFormat() throws {
        let watchPayload = Data(
            #"{"protocolVersion":1,"requestID":"12345678-1234-1234-1234-123456789ABC","sequence":1,"nextCursor":4,"samples":[{"id":"00000000-0000-0000-0000-000000000001","metric":"steps","value":3842.0,"unit":"count","startTime":1728000000000,"endTime":1728000060000,"source":"wearHealthServices","quality":"measured","revision":4},{"id":"00000000-0000-0000-0000-000000000002","metric":"totalCalories","value":80.0,"unit":"kilocalories","startTime":1728000000000,"endTime":1728000060000,"source":"wearHealthServices","quality":"measured","revision":4}]}"#.utf8
        )

        let batch = try ProtocolCodec.decode(HealthSyncBatch.self, from: watchPayload)

        XCTAssertEqual(batch.protocolVersion, ProtocolCodec.currentVersion)
        XCTAssertEqual(batch.sequence, 1)
        XCTAssertEqual(batch.nextCursor, 4)
        XCTAssertEqual(batch.requestID, UUID(uuidString: "12345678-1234-1234-1234-123456789ABC"))
        XCTAssertEqual(batch.samples.first?.source, .wearHealthServices)
        XCTAssertEqual(batch.samples.first?.startTime, Date(timeIntervalSince1970: 1_728_000_000))
        XCTAssertEqual(batch.samples.first?.endTime, Date(timeIntervalSince1970: 1_728_000_060))
        XCTAssertEqual(batch.samples.first?.revision, 4)
        XCTAssertEqual(batch.samples.last?.metric, .totalCalories)
    }

    func testRejectsNonAdvancingNonemptyBatch() throws {
        let batch = HealthSyncBatch(
            sequence: 4,
            nextCursor: 3,
            samples: [sample(id: "00000000-0000-0000-0000-000000000005", metric: .steps, value: 1)]
        )

        XCTAssertThrowsError(try HealthSyncBatchValidator.validate(batch, after: 3)) {
            XCTAssertEqual(
                $0 as? SynchronizationError,
                .nonAdvancingCursor(received: 3, current: 3)
            )
        }
    }

    func testRejectsBatchAboveProtocolSampleLimit() throws {
        let oneSample = sample(
            id: "00000000-0000-0000-0000-000000000006",
            metric: .steps,
            value: 1
        )
        let batch = HealthSyncBatch(
            sequence: 1,
            nextCursor: 1,
            samples: Array(repeating: oneSample, count: HealthSyncLimits.maximumSampleCount + 1)
        )

        XCTAssertThrowsError(try HealthSyncBatchValidator.validate(batch, after: 0)) {
            XCTAssertEqual(
                $0 as? SynchronizationError,
                .tooManySamples(
                    received: HealthSyncLimits.maximumSampleCount + 1,
                    maximum: HealthSyncLimits.maximumSampleCount
                )
            )
        }
    }

    func testFileStoreRejectsDevelopmentOnlySamples() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GalaxyCompanionDevelopmentSampleTests-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("health-sync.json")
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = try FileHealthSampleStore(fileURL: fileURL)
        let demoSample = HealthSample(
            metric: .steps,
            value: 1,
            unit: .count,
            startTime: Date(),
            source: .demo,
            quality: .measured
        )
        let batch = HealthSyncBatch(sequence: 1, nextCursor: 1, samples: [demoSample])

        do {
            _ = try await store.persist(batch)
            XCTFail("Expected development sample rejection")
        } catch let error as SynchronizationError {
            XCTAssertEqual(error, .developmentSampleRejected)
        }
    }

    private func sample(
        id: String,
        metric: HealthMetric,
        value: Double,
        revision: Int64 = 0
    ) -> HealthSample {
        HealthSample(
            id: UUID(uuidString: id)!,
            metric: metric,
            value: value,
            unit: metric == .heartRate ? .beatsPerMinute : .count,
            startTime: Date(timeIntervalSince1970: 1_700_000_000),
            source: .wearHealthServices,
            quality: .measured,
            revision: revision
        )
    }
}
