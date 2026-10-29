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
    /// A Watch-side recovery error sent as an authenticated GATT notification.
    /// It carries no health samples and never advances the iPhone cursor.
    public let failure: HealthSyncRemoteError?

    public init(
        protocolVersion: UInt16 = ProtocolCodec.currentVersion,
        requestID: UUID = UUID(),
        sequence: Int64,
        nextCursor: Int64,
        samples: [HealthSample],
        failure: HealthSyncRemoteError? = nil
    ) {
        self.protocolVersion = protocolVersion
        self.requestID = requestID
        self.sequence = sequence
        self.nextCursor = nextCursor
        self.samples = samples
        self.failure = failure
    }
}

public enum HealthSyncRemoteErrorCode: String, Codable, Equatable, Sendable {
    /// The phone's cursor refers to data that has aged out of the Watch's
    /// bounded local cache. The user must explicitly recover/reset sync state;
    /// normal sync must never skip that missing range silently.
    case retentionGap
}

public struct HealthSyncRemoteError: Codable, Equatable, Sendable {
    public let code: HealthSyncRemoteErrorCode
    /// Kept as this wire name for v1 compatibility. For `retentionGap`, this
    /// is the minimum safe `afterCursor` after an actual Watch-cache eviction;
    /// it is not inferred from the cursor on the first currently stored row.
    public let earliestAvailableCursor: Int64

    public init(code: HealthSyncRemoteErrorCode, earliestAvailableCursor: Int64) {
        self.code = code
        self.earliestAvailableCursor = earliestAvailableCursor
    }
}

public struct SyncReceipt: Equatable, Sendable {
    public let acknowledgedSequence: Int64
    public let cursor: Int64
    public let insertedSampleCount: Int
    public let updatedSampleCount: Int
    public let duplicateSampleCount: Int

    public init(
        acknowledgedSequence: Int64,
        cursor: Int64,
        insertedSampleCount: Int,
        updatedSampleCount: Int = 0,
        duplicateSampleCount: Int
    ) {
        self.acknowledgedSequence = acknowledgedSequence
        self.cursor = cursor
        self.insertedSampleCount = insertedSampleCount
        self.updatedSampleCount = updatedSampleCount
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
    case remoteFailure(HealthSyncRemoteErrorCode)
    case malformedRemoteFailure
    case conflictingSampleRevision(UUID)
    case synchronizationDidNotComplete
}

/// The application-layer batch cap is deliberately lower than the GATT
/// packet cap. It limits memory, persistence work and a single retry unit.
public enum HealthSyncLimits {
    public static let maximumSampleCount = 20
    /// The Watch retains at most 2,000 records. At least one sample must move
    /// the cursor in each nonempty batch, and a final empty response proves
    /// that the retained range is drained. Therefore a low-MTU, one-sample
    /// page needs at most 2,001 requests.
    public static let maximumBatchesPerSynchronization = 2_001
}

public enum HealthSyncBatchValidator {
    /// Validates semantics independent of BLE framing. A batch with values
    /// must advance the caller's cursor; an empty result must leave it in
    /// place. This prevents a malformed peer from silently skipping samples.
    public static func validate(_ batch: HealthSyncBatch, after cursor: Int64) throws {
        // A remote failure is also a no-progress response. Validate that
        // relation before converting it to the caller-visible error so a
        // corrupt peer cannot disguise a cursor jump as a retention signal.
        if let failure = batch.failure {
            try validateRemoteFailure(batch, failure: failure, after: cursor)
        }
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

    private static func validateRemoteFailure(
        _ batch: HealthSyncBatch,
        failure: HealthSyncRemoteError,
        after cursor: Int64
    ) throws {
        guard cursor >= 0 else {
            throw SynchronizationError.invalidCounter(cursor)
        }
        guard batch.sequence >= 0, batch.nextCursor >= 0 else {
            throw SynchronizationError.invalidCounter(min(batch.sequence, batch.nextCursor))
        }
        guard batch.protocolVersion == ProtocolCodec.currentVersion else {
            throw SynchronizationError.incompatibleProtocolVersion(batch.protocolVersion)
        }
        guard batch.samples.isEmpty,
              batch.nextCursor == cursor else {
            throw SynchronizationError.malformedRemoteFailure
        }
        guard failure.earliestAvailableCursor >= 0 else {
            throw SynchronizationError.invalidCounter(failure.earliestAvailableCursor)
        }
        throw SynchronizationError.remoteFailure(failure.code)
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
        if batch.failure != nil {
            guard batch.samples.isEmpty else {
                throw SynchronizationError.malformedRemoteFailure
            }
            guard batch.failure!.earliestAvailableCursor >= 0 else {
                throw SynchronizationError.invalidCounter(batch.failure!.earliestAvailableCursor)
            }
            throw SynchronizationError.remoteFailure(batch.failure!.code)
        }
        guard !batch.samples.contains(where: { $0.revision < 0 }) else {
            throw SynchronizationError.invalidCounter(
                batch.samples.first(where: { $0.revision < 0 })!.revision
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

        // Match the file-backed store's all-or-nothing behavior. A malformed
        // later sample must not leave an in-memory test/recovery store with a
        // partially applied page while its cursor still points at the prior
        // page.
        var updatedSampleIDs = sampleIDs
        var updatedSamples = samples
        var inserted = 0
        var updates = 0
        var duplicates = 0

        for sample in batch.samples {
            if updatedSampleIDs.insert(sample.id).inserted {
                updatedSamples.append(sample)
                inserted += 1
            } else {
                let index = updatedSamples.firstIndex(where: { $0.id == sample.id })!
                let existing = updatedSamples[index]
                switch Self.revisionDisposition(incoming: sample, existing: existing) {
                case .duplicate:
                    duplicates += 1
                case .replace:
                    updatedSamples[index] = sample
                    updates += 1
                case .conflict:
                    throw SynchronizationError.conflictingSampleRevision(sample.id)
                }
            }
        }

        sampleIDs = updatedSampleIDs
        samples = updatedSamples
        cursor = batch.nextCursor
        return SyncReceipt(
            acknowledgedSequence: batch.sequence,
            cursor: cursor,
            insertedSampleCount: inserted,
            updatedSampleCount: updates,
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

        var cursor = await store.currentCursor()
        var inserted = 0
        var updated = 0
        var duplicates = 0

        // A Watch cache is bounded at 2,000 records. This cap catches an
        // incorrectly behaving source without admitting an unbounded loop.
        for _ in 0..<HealthSyncLimits.maximumBatchesPerSynchronization {
            let batch = try await source.nextBatch(after: cursor, maximumSampleCount: maximumSampleCount)
            try HealthSyncBatchValidator.validate(batch, after: cursor)
            if batch.samples.isEmpty {
                return SyncReceipt(
                    // Include the terminal response too: it is the receipt
                    // proving that the cursor range has been fully drained.
                    acknowledgedSequence: batch.sequence,
                    cursor: cursor,
                    insertedSampleCount: inserted,
                    updatedSampleCount: updated,
                    duplicateSampleCount: duplicates
                )
            }
            let receipt = try await store.persist(batch)
            cursor = receipt.cursor
            inserted += receipt.insertedSampleCount
            updated += receipt.updatedSampleCount
            duplicates += receipt.duplicateSampleCount
        }
        throw SynchronizationError.synchronizationDidNotComplete
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

    /// Moves the local sync cursor only after the person explicitly accepts a
    /// Watch-reported retention gap. Existing samples are retained: the UI
    /// must make it clear that the historical range before this cursor cannot
    /// be recovered from the bounded Watch cache.
    public func advanceCursorForConfirmedRetentionRecovery(to cursor: Int64) throws {
        guard cursor >= state.cursor, cursor >= 0 else {
            throw SynchronizationError.regressiveCursor(received: cursor, current: state.cursor)
        }
        guard cursor != state.cursor else { return }

        var updatedState = state
        updatedState.cursor = cursor
        do {
            try Self.write(state: updatedState, to: fileURL)
            state = updatedState
        } catch {
            throw FileHealthSampleStoreError.unwritableStore
        }
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
        var updates = 0
        var duplicates = 0
        for sample in batch.samples {
            if updatedState.sampleIDs.insert(sample.id).inserted {
                updatedState.samples.append(sample)
                inserted += 1
            } else {
                guard let index = updatedState.samples.firstIndex(where: { $0.id == sample.id }) else {
                    throw SynchronizationError.conflictingSampleRevision(sample.id)
                }
                let existing = updatedState.samples[index]
                switch Self.revisionDisposition(incoming: sample, existing: existing) {
                case .duplicate:
                    duplicates += 1
                case .replace:
                    updatedState.samples[index] = sample
                    updates += 1
                case .conflict:
                    throw SynchronizationError.conflictingSampleRevision(sample.id)
                }
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
            updatedSampleCount: updates,
            duplicateSampleCount: duplicates
        )
    }

    private static func write(state: StoredState, to fileURL: URL) throws {
        let data = try ProtocolCodec.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }

    private enum RevisionDisposition {
        case duplicate
        case replace
        case conflict
    }

    private static func revisionDisposition(
        incoming: HealthSample,
        existing: HealthSample
    ) -> RevisionDisposition {
        if incoming.revision > existing.revision {
            return .replace
        }
        if incoming.revision < existing.revision || incoming == existing {
            return .duplicate
        }
        return .conflict
    }
}

private extension InMemoryHealthSampleStore {
    enum RevisionDisposition {
        case duplicate
        case replace
        case conflict
    }

    static func revisionDisposition(
        incoming: HealthSample,
        existing: HealthSample
    ) -> RevisionDisposition {
        if incoming.revision > existing.revision {
            return .replace
        }
        if incoming.revision < existing.revision || incoming == existing {
            return .duplicate
        }
        return .conflict
    }
}
