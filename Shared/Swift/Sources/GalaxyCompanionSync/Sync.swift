import Foundation
import GalaxyCompanionProtocol

public struct HealthSyncBatch: Codable, Equatable, Sendable {
    public let sequence: UInt64
    public let nextCursor: UInt64
    public let samples: [HealthSample]

    public init(sequence: UInt64, nextCursor: UInt64, samples: [HealthSample]) {
        self.sequence = sequence
        self.nextCursor = nextCursor
        self.samples = samples
    }
}

public struct SyncReceipt: Equatable, Sendable {
    public let acknowledgedSequence: UInt64
    public let cursor: UInt64
    public let insertedSampleCount: Int
    public let duplicateSampleCount: Int

    public init(
        acknowledgedSequence: UInt64,
        cursor: UInt64,
        insertedSampleCount: Int,
        duplicateSampleCount: Int
    ) {
        self.acknowledgedSequence = acknowledgedSequence
        self.cursor = cursor
        self.insertedSampleCount = insertedSampleCount
        self.duplicateSampleCount = duplicateSampleCount
    }
}

public protocol WatchHealthSyncSource: Sendable {
    func capabilities() async throws -> WatchCapabilities
    func nextBatch(after cursor: UInt64, maximumSampleCount: Int) async throws -> HealthSyncBatch
}

public protocol HealthSampleStore: Sendable {
    func currentCursor() async -> UInt64
    func persist(_ batch: HealthSyncBatch) async throws -> SyncReceipt
}

public enum SynchronizationError: Error, Equatable, Sendable {
    case invalidBatchLimit
    case regressiveCursor(received: UInt64, current: UInt64)
}

public actor InMemoryHealthSampleStore: HealthSampleStore {
    private var sampleIDs: Set<UUID> = []
    private var samples: [HealthSample] = []
    private var cursor: UInt64 = 0

    public init() {}

    public func currentCursor() -> UInt64 {
        cursor
    }

    public func allSamples() -> [HealthSample] {
        samples.sorted { $0.startTime < $1.startTime }
    }

    public func persist(_ batch: HealthSyncBatch) throws -> SyncReceipt {
        guard batch.nextCursor >= cursor else {
            throw SynchronizationError.regressiveCursor(received: batch.nextCursor, current: cursor)
        }

        var inserted = 0
        var duplicates = 0

        for sample in batch.samples {
            if sampleIDs.insert(sample.id).inserted {
                samples.append(sample)
                inserted += 1
            } else {
                duplicates += 1
            }
        }

        cursor = batch.nextCursor
        return SyncReceipt(
            acknowledgedSequence: batch.sequence,
            cursor: cursor,
            insertedSampleCount: inserted,
            duplicateSampleCount: duplicates
        )
    }
}

public struct HealthSyncCoordinator: Sendable {
    private let source: any WatchHealthSyncSource
    private let store: any HealthSampleStore

    public init(source: any WatchHealthSyncSource, store: any HealthSampleStore) {
        self.source = source
        self.store = store
    }

    public func synchronize(maximumSampleCount: Int = 200) async throws -> SyncReceipt {
        guard maximumSampleCount > 0 else {
            throw SynchronizationError.invalidBatchLimit
        }

        let cursor = await store.currentCursor()
        let batch = try await source.nextBatch(after: cursor, maximumSampleCount: maximumSampleCount)

        guard batch.nextCursor >= cursor else {
            throw SynchronizationError.regressiveCursor(received: batch.nextCursor, current: cursor)
        }

        return try await store.persist(batch)
    }
}

