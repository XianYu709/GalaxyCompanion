import Foundation
#if canImport(GalaxyCompanionProtocol)
import GalaxyCompanionProtocol
#endif

public struct HealthSyncBatch: Codable, Equatable, Sendable {
    public let protocolVersion: UInt16
    /// Echoes the request identifier supplied in `HealthSyncRequest`.
    public let requestID: UUID
    /// Signed, non-negative 63-bit counter shared with Kotlin `Long`.
    public let sequence: Int64
    /// Signed, non-negative 63-bit cursor shared with Kotlin `Long`.
    public let nextCursor: Int64
    public let samples: [HealthSample]

    public init(
        protocolVersion: UInt16 = ProtocolCodec.currentVersion,
        requestID: UUID = UUID(),
        sequence: Int64,
        nextCursor: Int64,
        samples: [HealthSample]
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sequence = sequence
        self.nextCursor = nextCursor
        self.samples = samples
    }
}

public struct SyncReceipt: Equatable, Sendable {
    public let acknowledgedSequence: Int64
    public let cursor: Int64
    public let insertedSampleCount: Int
    public let duplicateSampleCount: Int

    public init(
        acknowledgedSequence: Int64,
        cursor: Int64,
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
    func nextBatch(after cursor: Int64, maximumSampleCount: Int) async throws -> HealthSyncBatch
}

public protocol HealthSampleStore: Sendable {
    func currentCursor() async -> Int64
    func persist(_ batch: HealthSyncBatch) async throws -> SyncReceipt
}

public enum SynchronizationError: Error, Equatable, Sendable {
    case invalidBatchLimit
    case tooManySamples(received: Int, maximum: Int)
    case invalidCounter(Int64)
    case regressiveCursor(received: Int64, current: Int64)
    case nonAdvancingCursor(received: Int64, current: Int64)
    case emptyBatchAdvancedCursor(received: Int64, current: Int64)
    case incompatibleProtocolVersion(UInt16)
    case developmentSampleRejected
}

/// The application-layer batch cap is deliberately lower than the GATT
/// packet cap. It limits memory, persistence work and a single retry unit.
public enum HealthSyncLimits {
    public static let maximumSampleCount = 20
}

public enum HealthSyncBatchValidator {
    /// Validates semantics independent of BLE framing. A batch with values
    /// must advance the caller's cursor; an empty result must leave it in
    /// place. This prevents a malformed peer from silently skipping samples.
    public static func validate(_ batch: HealthSyncBatch, after cursor: Int64) throws {
        try validateShape(batch)
        guard cursor >= 0 else {
            throw SynchronizationError.invalidCounter(cursor)
        }
        guard batch.nextCursor >= cursor else {
            throw SynchronizationError.regressiveCursor(received: batch.nextCursor, current: cursor)
        }
        if batch.samples.isEmpty {
            guard batch.nextCursor == cursor else {
                throw SynchronizationError.emptyBatchAdvancedCursor(
                    received: batch.nextCursor,
                    current: cursor
                )
            }
        } else {
            guard batch.nextCursor > cursor else {
                throw SynchronizationError.nonAdvancingCursor(
                    received: batch.nextCursor,
                    current: cursor
                )
            }
        }
    }

    /// Validates an independently persisted batch before checking it against a
    /// particular request cursor. Stores use this so a byte-for-byte retry of
    /// an already committed batch remains idempotent.
    public static func validateShape(_ batch: HealthSyncBatch) throws {
        guard batch.sequence >= 0, batch.nextCursor >= 0 else {
            throw SynchronizationError.invalidCounter(min(batch.sequence, batch.nextCursor))
        }
        guard batch.protocolVersion == ProtocolCodec.currentVersion else {
            throw SynchronizationError.incompatibleProtocolVersion(batch.protocolVersion)
        }
        guard batch.samples.count <= HealthSyncLimits.maximumSampleCount else {
            throw SynchronizationError.tooManySamples(
                received: batch.samples.count,
                maximum: HealthSyncLimits.maximumSampleCount
            )
        }
    }
}

public actor InMemoryHealthSampleStore: HealthSampleStore {
    private var sampleIDs: Set<UUID> = []
    private var samples: [HealthSample] = []
    private var cursor: Int64 = 0

    public init() {}

    public func currentCursor() -> Int64 {
        cursor
    }

    public func allSamples() -> [HealthSample] {
        samples.sorted { $0.startTime < $1.startTime }
    }

    public func persist(_ batch: HealthSyncBatch) throws -> SyncReceipt {
        try HealthSyncBatchValidator.validateShape(batch)
        guard batch.nextCursor >= cursor else {
            throw SynchronizationError.regressiveCursor(received: batch.nextCursor, current: cursor)
        }
        if batch.samples.isEmpty {
            guard batch.nextCursor == cursor else {
                throw SynchronizationError.emptyBatchAdvancedCursor(
                    received: batch.nextCursor,
                    current: cursor
                )
            }
        } else if batch.nextCursor == cursor,
                    !batch.samples.allSatisfy({ sampleIDs.contains($0.id) }) {
            throw SynchronizationError.nonAdvancingCursor(received: batch.nextCursor, current: cursor)
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

    public func synchronize(maximumSampleCount: Int = HealthSyncLimits.maximumSampleCount) async throws -> SyncReceipt {
        guard maximumSampleCount > 0, maximumSampleCount <= HealthSyncLimits.maximumSampleCount else {
            throw SynchronizationError.invalidBatchLimit
        }

        let cursor = await store.currentCursor()
        let batch = try await source.nextBatch(after: cursor, maximumSampleCount: maximumSampleCount)

        try HealthSyncBatchValidator.validate(batch, after: cursor)

        return try await store.persist(batch)
    }
}

public enum FileHealthSampleStoreError: Error, Equatable, Sendable {
    case unreadableStore
    case unwritableStore
}

/// Production-direction local repository for the phone side of basic health
/// sync. It stores the cursor plus sample UUIDs atomically, so retrying a GATT
/// batch after an app restart cannot create duplicate records. This repository
/// deliberately does not write HealthKit; that remains a separate stage.
public actor FileHealthSampleStore: HealthSampleStore {
    private struct StoredState: Codable, Sendable {
        var cursor: Int64
        var sampleIDs: Set<UUID>
        var samples: [HealthSample]

        static let empty = StoredState(cursor: 0, sampleIDs: [], samples: [])
    }

    private let fileURL: URL
    private var state: StoredState

    public init(fileURL: URL) throws {
        self.fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                self.state = try ProtocolCodec.decode(StoredState.self, from: data)
            } else {
                self.state = .empty
                try Self.write(state: .empty, to: fileURL)
            }
        } catch {
            throw FileHealthSampleStoreError.unreadableStore
        }
    }

    public func currentCursor() -> Int64 {
        state.cursor
    }

    public func allSamples() -> [HealthSample] {
        state.samples.sorted { $0.startTime < $1.startTime }
    }

    public func persist(_ batch: HealthSyncBatch) throws -> SyncReceipt {
        try HealthSyncBatchValidator.validateShape(batch)
        guard batch.nextCursor >= state.cursor else {
            throw SynchronizationError.regressiveCursor(
                received: batch.nextCursor,
                current: state.cursor
            )
        }
        if batch.samples.isEmpty {
            guard batch.nextCursor == state.cursor else {
                throw SynchronizationError.emptyBatchAdvancedCursor(
                    received: batch.nextCursor,
                    current: state.cursor
                )
            }
        } else if batch.nextCursor == state.cursor,
                    !batch.samples.allSatisfy({ state.sampleIDs.contains($0.id) }) {
            throw SynchronizationError.nonAdvancingCursor(
                received: batch.nextCursor,
                current: state.cursor
            )
        }
        guard !batch.samples.contains(where: { $0.source == .demo }) else {
            throw SynchronizationError.developmentSampleRejected
        }

        var updatedState = state
        var inserted = 0
        var duplicates = 0
        for sample in batch.samples {
            if updatedState.sampleIDs.insert(sample.id).inserted {
                updatedState.samples.append(sample)
                inserted += 1
            } else {
                duplicates += 1
            }
        }
        updatedState.cursor = batch.nextCursor

        do {
            try Self.write(state: updatedState, to: fileURL)
        } catch {
            throw FileHealthSampleStoreError.unwritableStore
        }
        state = updatedState

        return SyncReceipt(
            acknowledgedSequence: batch.sequence,
            cursor: state.cursor,
            insertedSampleCount: inserted,
            duplicateSampleCount: duplicates
        )
    }

    private static func write(state: StoredState, to fileURL: URL) throws {
        let data = try ProtocolCodec.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}
