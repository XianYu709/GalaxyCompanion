import Foundation
import HealthKit

/// Value-level boundary around HealthKit. Tests can substitute this protocol
/// without loading HealthKit or accessing a user's health database.
@MainActor
protocol HealthKitStoreClient: AnyObject {
    var isHealthDataAvailable: Bool { get }

    func authorizationRequestStatus(
        for types: Set<AppleHealthQuantityType>
    ) async throws -> HealthKitAuthorizationRequestStatus
    func sharingAuthorizationStatus(
        for type: AppleHealthQuantityType
    ) -> HealthKitSharingAuthorizationStatus
    func requestAuthorization(
        toShare types: Set<AppleHealthQuantityType>
    ) async throws
    func save(_ payload: AppleHealthSamplePayload) async throws
    /// Removes only a GalaxyCompanion sample identified by its exact HealthKit
    /// sync identifier and quantity type. It is used for a cumulative Watch
    /// correction which invalidates a previously exported positive interval.
    func delete(_ removal: AppleHealthCumulativeRemoval) async throws
}

enum HealthKitAuthorizationRequestStatus: Equatable {
    case unknown
    case shouldRequest
    case unnecessary
}

enum HealthKitSharingAuthorizationStatus: Equatable {
    case notDetermined
    case denied
    case authorized
}

/// User-visible write authorization state. HealthKit intentionally does not
/// disclose read authorization; GalaxyCompanion only requests write access in
/// this phase, so these values represent the actual share permissions.
enum HealthKitAuthorizationState: Equatable {
    case checking
    case unavailable(String)
    case needsAuthorization
    case authorized
    case partiallyAuthorized(authorized: Int, deniedOrUndetermined: Int)
    case denied
    case unknown
    case failed(String)

    var title: String {
        switch self {
        case .checking: "正在检查 Apple Health 授权"
        case .unavailable: "Apple Health 不可用"
        case .needsAuthorization: "需要 Apple Health 写入授权"
        case .authorized: "Apple Health 写入已授权"
        case .partiallyAuthorized: "Apple Health 仅部分授权"
        case .denied: "Apple Health 写入未获授权"
        case .unknown: "Apple Health 授权状态未知"
        case .failed: "无法检查 Apple Health 授权"
        }
    }

    var detail: String {
        switch self {
        case .checking:
            "正在检查可写入的健康数据类型。"
        case .unavailable(let reason), .failed(let reason):
            reason
        case .needsAuthorization:
            "当前仅请求写入步数、心率和距离。日总能量保留在本应用。"
        case .authorized:
            "授权不等于已经写入；真实手表数据仍受认证配对和实机 PoC 的安全门控。"
        case .partiallyAuthorized(let authorized, let unavailable):
            "已授权 \(authorized) 项，另有 \(unavailable) 项未获授权或尚未决定；写入会逐项报告。"
        case .denied:
            "未写入任何数据。可在“健康”中重新允许 GalaxyCompanion 写入后再试。"
        case .unknown:
            "系统无法判断是否需要弹出授权。不会尝试写入数据。"
        }
    }

    var canRequestAuthorization: Bool {
        switch self {
        case .needsAuthorization, .partiallyAuthorized, .denied, .unknown, .failed:
            true
        case .checking, .unavailable, .authorized:
            false
        }
    }
}

struct HealthKitExportReport: Equatable {
    let writtenSampleCount: Int
    let removedSampleCount: Int
    let previouslyWrittenSampleCount: Int
    let rejectedSampleCount: Int
    let failures: [String]
}

enum HealthKitExportResult: Equatable {
    case exported(HealthKitExportReport)
    case partialFailure(HealthKitExportReport)
    case failed(HealthKitExportReport)
    case blockedUntrustedData
    case unavailable(String)
}

/// Stores the highest successfully committed revision for every stable sample
/// identifier. This is the local idempotency guard for normal retries while
/// allowing HealthKit's sync identifier/version pair to replace a corrected
/// sample instead of creating a second measurement.
protocol HealthKitExportLedger: Sendable {
    func writtenRevision(for sampleID: UUID) async -> Int64?
    func recordWritten(_ sampleID: UUID, revision: Int64) async throws
    func removeWritten(_ sampleID: UUID) async throws
}

enum HealthKitExportLedgerError: Error, LocalizedError {
    case unreadable
    case unwritable

    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取 Apple Health 写入记录。"
        case .unwritable: "无法保存 Apple Health 写入记录。"
        }
    }
}

actor FileHealthKitExportLedger: HealthKitExportLedger {
    private struct State: Codable {
        var writtenRevisions: [UUID: Int64]

        private enum CodingKeys: String, CodingKey {
            case writtenRevisions
            case sampleIDs
        }

        init(writtenRevisions: [UUID: Int64]) {
            self.writtenRevisions = writtenRevisions
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if let revisions = try container.decodeIfPresent([UUID: Int64].self, forKey: .writtenRevisions) {
                writtenRevisions = revisions
            } else {
                // The previous on-disk ledger tracked only identifiers. Those
                // writes used HealthKit sync version 1, so preserve that exact
                // idempotency behavior when migrating it.
                let legacyIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .sampleIDs) ?? []
                writtenRevisions = Dictionary(uniqueKeysWithValues: legacyIDs.map { ($0, 1) })
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(writtenRevisions, forKey: .writtenRevisions)
        }
    }

    private let fileURL: URL
    private var state: State

    init(fileURL: URL) throws {
        self.fileURL = fileURL
        let directoryURL = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let data = try Data(contentsOf: fileURL)
                state = try JSONDecoder().decode(State.self, from: data)
            } else {
                state = State(writtenRevisions: [:])
                try Self.write(state, to: fileURL)
            }
        } catch {
            throw HealthKitExportLedgerError.unreadable
        }
    }

    func writtenRevision(for sampleID: UUID) -> Int64? {
        state.writtenRevisions[sampleID]
    }

    func recordWritten(_ sampleID: UUID, revision: Int64) throws {
        guard revision >= 1 else { throw HealthKitExportLedgerError.unwritable }
        guard state.writtenRevisions[sampleID, default: 0] < revision else { return }
        var updatedState = state
        updatedState.writtenRevisions[sampleID] = revision
        do {
            try Self.write(updatedState, to: fileURL)
            state = updatedState
        } catch {
            throw HealthKitExportLedgerError.unwritable
        }
    }

    func removeWritten(_ sampleID: UUID) throws {
        guard state.writtenRevisions[sampleID] != nil else { return }
        var updatedState = state
        updatedState.writtenRevisions.removeValue(forKey: sampleID)
        do {
            try Self.write(updatedState, to: fileURL)
            state = updatedState
        } catch {
            throw HealthKitExportLedgerError.unwritable
        }
    }

    private static func write(_ state: State, to fileURL: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
    }
}

/// Owns authorization inspection and controlled writes. It receives samples
/// only from higher-level workflows; it never starts BLE synchronisation and
/// therefore cannot weaken the existing physical-transfer fail-closed gate.
@MainActor
final class HealthKitExportService {
    private let store: any HealthKitStoreClient
    private let ledger: any HealthKitExportLedger

    init(store: any HealthKitStoreClient, ledger: any HealthKitExportLedger) {
        self.store = store
        self.ledger = ledger
    }

    convenience init() throws {
        try self.init(
            store: SystemHealthKitStoreClient(),
            ledger: FileHealthKitExportLedger(fileURL: Self.defaultLedgerURL())
        )
    }

    func refreshAuthorization() async -> HealthKitAuthorizationState {
        guard store.isHealthDataAvailable else {
            return .unavailable("此设备或运行环境不支持 Apple Health。")
        }

        do {
            let requestStatus = try await store.authorizationRequestStatus(
                for: AppleHealthSampleMapper.authorizationQuantityTypes
            )
            let statusCounts = sharingStatusCounts()
            let total = AppleHealthSampleMapper.authorizationQuantityTypes.count

            if statusCounts.authorized == total {
                return .authorized
            }
            if statusCounts.authorized > 0 {
                return .partiallyAuthorized(
                    authorized: statusCounts.authorized,
                    deniedOrUndetermined: total - statusCounts.authorized
                )
            }
            if statusCounts.denied == total {
                return .denied
            }
            switch requestStatus {
            case .shouldRequest:
                return .needsAuthorization
            case .unknown, .unnecessary:
                return .unknown
            }
        } catch {
            return .failed("检查 Apple Health 授权失败：\(error.localizedDescription)")
        }
    }

    func requestAuthorization() async -> HealthKitAuthorizationState {
        guard store.isHealthDataAvailable else {
            return .unavailable("此设备或运行环境不支持 Apple Health。")
        }

        do {
            // Apple's completion only confirms that the request flow ended,
            // not that every type was granted. Always re-read per-type share
            // status before reporting success or attempting a write.
            try await store.requestAuthorization(
                toShare: AppleHealthSampleMapper.authorizationQuantityTypes
            )
            return await refreshAuthorization()
        } catch {
            return .failed("Apple Health 授权请求未完成：\(error.localizedDescription)")
        }
    }

    /// Exports only explicitly authenticated measurement data. The caller
    /// owns BLE synchronization; this service cannot weaken its pairing gate.
    func export(
        _ samples: [HealthSample],
        dataMode: HealthDataMode
    ) async -> HealthKitExportResult {
        guard store.isHealthDataAvailable else {
            return .unavailable("此设备或运行环境不支持 Apple Health。")
        }
        guard dataMode == .authenticatedMeasurement else {
            return .blockedUntrustedData
        }

        let plan = AppleHealthCumulativeNormalizer.exportPlan(from: samples)
        var payloads: [AppleHealthSamplePayload] = []
        var rejected = 0
        var failures: [String] = []
        for sample in plan.samples {
            switch AppleHealthSampleMapper.map(sample) {
            case .success(let payload):
                payloads.append(payload)
            case .failure(let error):
                rejected += 1
                failures.append("\(sample.id.uuidString): \(String(describing: error))")
            }
        }

        var written = 0
        var removed = 0
        var previouslyWritten = 0

        for removal in plan.removals {
            // No positive value for this stable interval has reached HealthKit
            // from this device, so there is nothing app-owned to retract.
            guard await ledger.writtenRevision(for: removal.id) != nil else { continue }
            switch store.sharingAuthorizationStatus(for: removal.quantityType) {
            case .authorized:
                break
            case .denied, .notDetermined:
                failures.append(
                    "\(removal.id.uuidString): 未获得 \(removal.quantityType.rawValue) 的写入授权，无法移除已被 Watch 修正的旧值。"
                )
                continue
            }

            do {
                // Keep the ledger entry until HealthKit confirms deletion.
                // This makes an interrupted correction retryable and prevents
                // a stale positive cumulative interval from being forgotten.
                try await store.delete(removal)
                try await ledger.removeWritten(removal.id)
                removed += 1
            } catch {
                failures.append("\(removal.id.uuidString): 无法移除已被 Watch 修正的旧值：\(error.localizedDescription)")
            }
        }

        for payload in payloads {
            switch store.sharingAuthorizationStatus(for: payload.quantityType) {
            case .authorized:
                break
            case .denied, .notDetermined:
                failures.append("\(payload.id.uuidString): 未获得 \(payload.quantityType.rawValue) 的写入授权。")
                continue
            }

            let revision = Int64(payload.metadata.syncVersion)
            if let writtenRevision = await ledger.writtenRevision(for: payload.id),
               writtenRevision >= revision {
                previouslyWritten += 1
                continue
            }

            do {
                // Save a single sample at a time so a failure has an exact
                // sample identity and can be safely retried later.
                try await store.save(payload)
                try await ledger.recordWritten(payload.id, revision: revision)
                written += 1
            } catch {
                failures.append("\(payload.id.uuidString): \(error.localizedDescription)")
            }
        }

        let report = HealthKitExportReport(
            writtenSampleCount: written,
            removedSampleCount: removed,
            previouslyWrittenSampleCount: previouslyWritten,
            rejectedSampleCount: rejected,
            failures: failures
        )
        if failures.isEmpty {
            return .exported(report)
        }
        if written > 0 || removed > 0 || previouslyWritten > 0 {
            return .partialFailure(report)
        }
        return .failed(report)
    }

    private func sharingStatusCounts() -> (authorized: Int, denied: Int) {
        AppleHealthSampleMapper.authorizationQuantityTypes.reduce(into: (authorized: 0, denied: 0)) {
            counts,
            type in
            switch store.sharingAuthorizationStatus(for: type) {
            case .authorized:
                counts.authorized += 1
            case .denied:
                counts.denied += 1
            case .notDetermined:
                break
            }
        }
    }

    private static func defaultLedgerURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appendingPathComponent("GalaxyCompanion", isDirectory: true)
            .appendingPathComponent("healthkit-export-ledger.json")
    }
}

@MainActor
private final class SystemHealthKitStoreClient: HealthKitStoreClient {
    private enum MetadataKey {
        static let source = "com.galaxycompanion.health.source"
    }

    private let healthStore = HKHealthStore()

    var isHealthDataAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func authorizationRequestStatus(
        for types: Set<AppleHealthQuantityType>
    ) async throws -> HealthKitAuthorizationRequestStatus {
        let sampleTypes = try healthKitSampleTypes(for: types)
        let status = try await healthStore.statusForAuthorizationRequest(
            toShare: sampleTypes,
            read: []
        )
        switch status {
        case .unknown:
            return .unknown
        case .shouldRequest:
            return .shouldRequest
        case .unnecessary:
            return .unnecessary
        @unknown default:
            return .unknown
        }
    }

    func sharingAuthorizationStatus(
        for type: AppleHealthQuantityType
    ) -> HealthKitSharingAuthorizationStatus {
        guard let quantityType = type.healthKitQuantityType else { return .denied }
        switch healthStore.authorizationStatus(for: quantityType) {
        case .notDetermined:
            return .notDetermined
        case .sharingDenied:
            return .denied
        case .sharingAuthorized:
            return .authorized
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization(
        toShare types: Set<AppleHealthQuantityType>
    ) async throws {
        let sampleTypes = try healthKitSampleTypes(for: types)
        try await healthStore.requestAuthorization(toShare: sampleTypes, read: [])
    }

    func save(_ payload: AppleHealthSamplePayload) async throws {
        guard let quantityType = payload.quantityType.healthKitQuantityType,
              let healthKitUnit = payload.unit.healthKitUnit else {
            throw SystemHealthKitStoreError.unsupportedPayload
        }

        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: payload.metadata.syncIdentifier,
            HKMetadataKeySyncVersion: NSNumber(value: payload.metadata.syncVersion),
            HKMetadataKeyExternalUUID: payload.metadata.externalUUID,
            MetadataKey.source: payload.metadata.source
        ]
        let sample = HKQuantitySample(
            type: quantityType,
            quantity: HKQuantity(unit: healthKitUnit, doubleValue: payload.value),
            start: payload.startDate,
            end: payload.endDate,
            metadata: metadata
        )
        try await healthStore.save(sample)
    }

    func delete(_ removal: AppleHealthCumulativeRemoval) async throws {
        guard let quantityType = removal.quantityType.healthKitQuantityType else {
            throw SystemHealthKitStoreError.unsupportedPayload
        }
        // Apple documents that this API deletes only objects this application
        // saved, and the metadata predicate narrows that further to the exact
        // GalaxyCompanion sync identifier. See:
        // https://developer.apple.com/documentation/healthkit/hkhealthstore/deleteobjects(of:predicate:withcompletion:)
        let predicate = HKQuery.predicateForObjects(
            withMetadataKey: HKMetadataKeySyncIdentifier,
            allowedValues: [removal.syncIdentifier]
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            healthStore.deleteObjects(of: quantityType, predicate: predicate) { success, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SystemHealthKitStoreError.deletionFailed)
                }
            }
        }
    }

    private func healthKitSampleTypes(
        for types: Set<AppleHealthQuantityType>
    ) throws -> Set<HKSampleType> {
        let sampleTypes = types.compactMap(\.healthKitQuantityType)
        guard sampleTypes.count == types.count else {
            throw SystemHealthKitStoreError.unsupportedPayload
        }
        return Set(sampleTypes)
    }
}

private enum SystemHealthKitStoreError: LocalizedError {
    case unsupportedPayload
    case deletionFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedPayload:
            "HealthKit 不支持此 GalaxyCompanion 健康样本。"
        case .deletionFailed:
            "HealthKit 未确认移除已被 Watch 修正的旧健康样本。"
        }
    }
}

private extension AppleHealthQuantityType {
    var healthKitQuantityType: HKQuantityType? {
        let identifier: HKQuantityTypeIdentifier
        switch self {
        case .stepCount: identifier = .stepCount
        case .heartRate: identifier = .heartRate
        case .activeEnergyBurned: identifier = .activeEnergyBurned
        case .distanceWalkingRunning: identifier = .distanceWalkingRunning
        case .flightsClimbed: identifier = .flightsClimbed
        case .oxygenSaturation: identifier = .oxygenSaturation
        case .bodyTemperature: identifier = .bodyTemperature
        }
        return HKObjectType.quantityType(forIdentifier: identifier)
    }
}

private extension AppleHealthUnit {
    var healthKitUnit: HKUnit? {
        switch self {
        case .count: .count()
        case .countPerMinute: HKUnit.count().unitDivided(by: .minute())
        case .kilocalorie: .kilocalorie()
        case .meter: .meter()
        case .percent: .percent()
        case .degreeCelsius: .degreeCelsius()
        }
    }
}
