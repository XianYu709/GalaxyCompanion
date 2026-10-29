import Foundation

struct HealthSyncSnapshot: Equatable {
    let insertedSampleCount: Int
    let updatedSampleCount: Int
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

enum BLEHealthSyncServiceError: LocalizedError {
    case synchronizationAlreadyInProgress
    case transportFailure(String)
    case responseTimedOut
    case retentionGap(earliestAvailableCursor: Int64)
    case synchronizationDidNotComplete

    var errorDescription: String? {
        switch self {
        case .synchronizationAlreadyInProgress:
            "已有一项健康同步正在进行。"
        case .transportFailure(let reason):
            reason
        case .responseTimedOut:
            "等待手表健康同步数据超时。"
        case .retentionGap(let earliestAvailableCursor):
            "手表缓存容量已淘汰部分尚未同步的数据（恢复 cursor：\(earliestAvailableCursor)）。为避免静默丢失，已停止同步；请在诊断中确认后将同步起点重设为该 cursor。"
        case .synchronizationDidNotComplete:
            "同步批次超过本地缓存上限，已停止以避免无限循环。"
        }
    }
}

/// iPhone-side Phase 2 health-sync use case. It owns a file-backed local
/// repository and asks the transport only for value-type protocol batches.
/// HealthKit is intentionally not referenced in this type.
@MainActor
final class BLEHealthSyncService: HealthSyncing {
    private let transport: any WatchTransport
    private let store: FileHealthSampleStore
    private var pendingContinuation: CheckedContinuation<HealthSyncBatch, Error>?
    private var pendingRequest: PendingRequest?

    var onTransportEvent: ((HealthSyncTransportEvent) -> Void)?

    init(transport: any WatchTransport, fileURL: URL? = nil) throws {
        self.transport = transport
        self.store = try FileHealthSampleStore(fileURL: fileURL ?? Self.defaultStoreURL())
        transport.onHealthSyncEvent = { [weak self] event in
            self?.handleTransportEvent(event)
        }
    }

    /// Reads only the phone's durable cache. It never starts Bluetooth work,
    /// so the UI can show the last successfully stored measurements at launch.
    func cachedSnapshot() async -> HealthSyncSnapshot {
        HealthSyncSnapshot(
            insertedSampleCount: 0,
            updatedSampleCount: 0,
            duplicateSampleCount: 0,
            cursor: await store.currentCursor(),
            samples: await store.allSamples()
        )
    }

    /// This is intentionally separate from normal synchronization. A caller
    /// must show the Watch-reported loss boundary and receive explicit user
    /// confirmation before moving the durable iPhone cursor past it.
    func recoverFromConfirmedRetentionGap(
        earliestAvailableCursor: Int64
    ) async throws -> HealthSyncSnapshot {
        try await store.advanceCursorForConfirmedRetentionRecovery(
            to: earliestAvailableCursor
        )
        return await cachedSnapshot()
    }

    func synchronize() async throws -> HealthSyncSnapshot {
        guard pendingContinuation == nil else {
            throw BLEHealthSyncServiceError.synchronizationAlreadyInProgress
        }
        var cursor = await store.currentCursor()
        var inserted = 0
        var updated = 0
        var duplicates = 0

        // Health Services data can accumulate while the iPhone is offline.
        // The Watch bounds that cache to 2,000 rows; every nonempty valid
        // response must advance this cursor, then one final empty response
        // proves completion. The shared 2,001-request guard is enough even
        // when ATT MTU forces one sample per page.
        for _ in 0..<HealthSyncLimits.maximumBatchesPerSynchronization {
            let batch = try await requestBatch(after: cursor)
            if batch.samples.isEmpty {
                return HealthSyncSnapshot(
                    insertedSampleCount: inserted,
                    updatedSampleCount: updated,
                    duplicateSampleCount: duplicates,
                    cursor: cursor,
                    samples: await store.allSamples()
                )
            }
            let receipt = try await store.persist(batch)
            cursor = receipt.cursor
            inserted += receipt.insertedSampleCount
            updated += receipt.updatedSampleCount
            duplicates += receipt.duplicateSampleCount
        }
        throw BLEHealthSyncServiceError.synchronizationDidNotComplete
    }

    private func requestBatch(after cursor: Int64) async throws -> HealthSyncBatch {
        let requestID = UUID()
        let pending = PendingRequest(
            id: requestID,
            afterCursor: cursor,
            maximumSampleCount: UInt16(HealthSyncLimits.maximumSampleCount)
        )
        return try await withCheckedThrowingContinuation { continuation in
            pendingContinuation = continuation
            pendingRequest = pending
            transport.requestHealthSync(
                requestID: requestID,
                after: cursor,
                maximumSampleCount: pending.maximumSampleCount
            )

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                self?.expireRequestIfNeeded(requestID)
            }
        }
    }

    private func handleTransportEvent(_ event: HealthSyncTransportEvent) {
        onTransportEvent?(event)

        switch event {
        case .requestSent:
            break
        case .batchReceived(let batch):
            guard let pending = pendingRequest, batch.requestID == pending.id else {
                // A delayed notification from a previous connection must never
                // complete the current continuation or reach local storage.
                return
            }
            if let failure = batch.failure {
                guard batch.protocolVersion == ProtocolCodec.currentVersion,
                      batch.samples.isEmpty,
                      batch.nextCursor == pending.afterCursor,
                      failure.earliestAvailableCursor >= 0 else {
                    completePendingRequest(throwing: SynchronizationError.malformedRemoteFailure)
                    return
                }
                switch failure.code {
                case .retentionGap:
                    completePendingRequest(
                        throwing: BLEHealthSyncServiceError.retentionGap(
                            earliestAvailableCursor: failure.earliestAvailableCursor
                        )
                    )
                }
                return
            }
            do {
                try HealthSyncBatchValidator.validate(batch, after: pending.afterCursor)
                guard batch.samples.count <= Int(pending.maximumSampleCount) else {
                    throw SynchronizationError.tooManySamples(
                        received: batch.samples.count,
                        maximum: Int(pending.maximumSampleCount)
                    )
                }
            } catch {
                completePendingRequest(throwing: error)
                return
            }
            let continuation = pendingContinuation
            pendingContinuation = nil
            pendingRequest = nil
            continuation?.resume(returning: batch)
        case .failed(let reason):
            completePendingRequest(throwing: BLEHealthSyncServiceError.transportFailure(reason))
        }
    }

    private func expireRequestIfNeeded(_ requestID: UUID) {
        guard pendingRequest?.id == requestID else { return }
        completePendingRequest(throwing: BLEHealthSyncServiceError.responseTimedOut)
    }

    private func completePendingRequest(throwing error: Error) {
        let continuation = pendingContinuation
        pendingContinuation = nil
        pendingRequest = nil
        continuation?.resume(throwing: error)
    }

    private struct PendingRequest {
        let id: UUID
        let afterCursor: Int64
        let maximumSampleCount: UInt16
    }

    private static func defaultStoreURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("GalaxyCompanion", isDirectory: true)
            .appendingPathComponent("basic-health-sync.json")
    }
}
