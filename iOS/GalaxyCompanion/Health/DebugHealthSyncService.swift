import Foundation

struct HealthSyncSnapshot: Equatable {
    let insertedSampleCount: Int
    let duplicateSampleCount: Int
    /// Signed, non-negative 63-bit cursor, matching the Watch `Long` wire contract.
    let cursor: Int64
    let samples: [HealthSample]
}

@MainActor
protocol HealthSyncing: AnyObject {
    var onTransportEvent: ((HealthSyncTransportEvent) -> Void)? { get set }
    func synchronize() async throws -> HealthSyncSnapshot
}

/// Runs the shared cursor and deduplication path with deterministic samples.
/// This is intentionally simulator-only; it is not a replacement for data
/// read from a physical Watch GATT connection.
@MainActor
final class DebugHealthSyncService: HealthSyncing {
    private let store: InMemoryHealthSampleStore
    private let coordinator: HealthSyncCoordinator
    var onTransportEvent: ((HealthSyncTransportEvent) -> Void)?

    init() {
        let source = FakeWatchSyncSource(
            capabilities: WatchCapabilities(
                identity: WatchIdentity(
                    model: "GalaxyCompanion Debug Watch",
                    wearOSVersion: "Simulator",
                    firmwareVersion: "0.1.0-debug"
                ),
                enabled: [.heartRate, .steps, .calories, .distance],
                healthDataMode: .developmentSynthetic
            ),
            samples: Self.seedSamples
        )
        let store = InMemoryHealthSampleStore()
        self.store = store
        self.coordinator = HealthSyncCoordinator(source: source, store: store)
    }

    func synchronize() async throws -> HealthSyncSnapshot {
        let receipt = try await coordinator.synchronize()
        return HealthSyncSnapshot(
            insertedSampleCount: receipt.insertedSampleCount,
            duplicateSampleCount: receipt.duplicateSampleCount,
            cursor: receipt.cursor,
            samples: await store.allSamples()
        )
    }

    private static let seedSamples: [HealthSample] = [
        HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            metric: .steps,
            value: 3_842,
            unit: .count,
            startTime: Date(timeIntervalSince1970: 1_728_000_000),
            source: .demo,
            quality: .measured
        ),
        HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            metric: .heartRate,
            value: 72,
            unit: .beatsPerMinute,
            startTime: Date(timeIntervalSince1970: 1_728_000_300),
            source: .demo,
            quality: .measured
        ),
        HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            metric: .activeCalories,
            value: 184,
            unit: .kilocalories,
            startTime: Date(timeIntervalSince1970: 1_728_000_600),
            source: .demo,
            quality: .estimated
        ),
        HealthSample(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            metric: .distance,
            value: 2_760,
            unit: .meters,
            startTime: Date(timeIntervalSince1970: 1_728_000_900),
            source: .demo,
            quality: .measured
        )
    ]
}
