import Foundation

enum BLEHealthSyncServiceError: LocalizedError {
    case synchronizationAlreadyInProgress
    case physicalTransferBlockedUntilAuthenticatedPairing
    case transportFailure(String)
    case responseTimedOut

    var errorDescription: String? {
        switch self {
        case .synchronizationAlreadyInProgress:
            "已有一项健康同步正在进行。"
        case .physicalTransferBlockedUntilAuthenticatedPairing:
            "真实手表健康传输已禁用：尚未实现并验证认证配对，不能把 BLE 数据当作生产健康样本。"
        case .transportFailure(let reason):
            reason
        case .responseTimedOut:
            "等待手表健康同步数据超时。"
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

    func synchronize() async throws -> HealthSyncSnapshot {
        guard pendingContinuation == nil else {
            throw BLEHealthSyncServiceError.synchronizationAlreadyInProgress
        }
        // GATT link encryption/authentication and application-level pairing
        // are not designed or verified yet. Never persist a physical Watch's
        // bytes as production health data before that boundary exists.
        guard transport.mode != .hardware else {
            throw BLEHealthSyncServiceError.physicalTransferBlockedUntilAuthenticatedPairing
        }

        let cursor = await store.currentCursor()
        let batch = try await requestBatch(after: cursor)
        let receipt = try await store.persist(batch)
        return HealthSyncSnapshot(
            insertedSampleCount: receipt.insertedSampleCount,
            duplicateSampleCount: receipt.duplicateSampleCount,
            cursor: receipt.cursor,
            samples: await store.allSamples()
        )
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
