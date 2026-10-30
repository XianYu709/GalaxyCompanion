import Observation
import SwiftUI

@main
struct GalaxyCompanionApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView(appState: appState)
        }
    }
}

@Observable
@MainActor
final class AppState {
    private let transport: any WatchTransport
    private let healthSyncService: BLEHealthSyncService?
    private let healthKitExportService: HealthKitExportService?

    private(set) var transportMode: WatchTransportMode
    private(set) var connectionState: WatchTransportState
    private(set) var capabilities: WatchCapabilities?
    private(set) var pairingStatus: WatchPairingStatus
    private(set) var healthSyncStatus: HealthSyncStatus
    private(set) var healthKitAuthorizationStatus: HealthKitAuthorizationState
    private(set) var healthKitExportStatus: HealthKitExportStatus = .idle
    private(set) var healthSamples: [HealthSample] = []
    private(set) var sleepAnalysis: LocalSleepAnalysis = .unavailable(.noSynchronizedData)
    private(set) var retentionRecoveryCursor: Int64?
    private(set) var retentionRecoveryNotice: String?
    private(set) var lastSyncAt: Date?
    // A Health-tab tap can start the protected pairing read first. Keep that
    // explicit intent only for the current connection, then continue the
    // same manual pull after the Watch re-publishes authenticated capability.
    private var synchronizeAfterPairing = false

    init(transport: (any WatchTransport)? = nil) {
        let selectedTransport = transport ?? Self.defaultTransport()
        self.transport = selectedTransport
        transportMode = selectedTransport.mode
        connectionState = selectedTransport.state
        pairingStatus = .notChecked

        do {
            healthSyncService = try BLEHealthSyncService(transport: selectedTransport)
        } catch {
            healthSyncService = nil
        }

        do {
            healthKitExportService = try HealthKitExportService()
            healthKitAuthorizationStatus = .checking
        } catch {
            healthKitExportService = nil
            healthKitAuthorizationStatus = .unavailable(
                "无法初始化 Apple Health 写入记录：\(error.localizedDescription)"
            )
        }

        healthSyncStatus = .blocked("先连接 Watch、完成当前连接的系统安全配对，并验证数据权限。")

        selectedTransport.onStateChange = { [weak self] state in
            self?.connectionState = state
            if case .connected = state {
                self?.refreshSyncAvailability()
            } else {
                self?.pairingStatus = .notChecked
                self?.synchronizeAfterPairing = false
                self?.refreshSyncAvailability()
            }
        }
        selectedTransport.onCapabilitiesChange = { [weak self] capabilities in
            self?.capabilities = capabilities
            self?.refreshSyncAvailability()
            self?.continueSynchronizationAfterPairingIfReady()
        }
        selectedTransport.onPairingStatusChange = { [weak self] status in
            self?.pairingStatus = status
            if case .failed = status {
                self?.synchronizeAfterPairing = false
            }
            self?.refreshSyncAvailability()
        }

        if healthKitExportService != nil {
            Task { [weak self] in
                await self?.refreshHealthKitAuthorization()
            }
        }
        if healthSyncService != nil {
            Task { [weak self] in
                await self?.loadCachedHealthSnapshot()
            }
        }
    }

    var isConnected: Bool {
        if case .connected = connectionState { return true }
        return false
    }

    var canSynchronize: Bool {
        guard isConnected,
              pairingStatus == .trustedForCurrentConnection,
              capabilities?.healthDataMode == .authenticatedMeasurement,
              healthSyncService != nil else {
            return false
        }
        return !isSyncing
    }

    var canExportToAppleHealth: Bool {
        !healthSamples.isEmpty &&
            hasAppleHealthExportableSamples &&
            transportMode == .hardware &&
            healthKitAuthorizationStatus.canExportAuthorizedData &&
            healthKitExportService != nil &&
            !isExporting
    }

    var isSyncing: Bool {
        if case .syncing = healthSyncStatus { return true }
        return false
    }

    var isExporting: Bool {
        if case .exporting = healthKitExportStatus { return true }
        return false
    }

    var syncRequirementDetail: String {
        guard isConnected else {
            return "先在 Watch 打开 GalaxyCompanion 并启动 BLE，然后在这里搜索。"
        }
        guard pairingStatus == .trustedForCurrentConnection else {
            return "连接已建立；还需要验证当前 BLE 会话的系统安全配对。"
        }
        guard capabilities?.healthDataMode == .authenticatedMeasurement else {
            return "Watch 尚未在当前受保护连接上确认健康数据权限。完成配对后再次验证。"
        }
        return "已满足安全同步条件。"
    }

    var appleHealthExportRequirementDetail: String {
        guard transportMode == .hardware else {
            return "模拟传输不会写入 Apple Health。请在真实 iPhone 与 Watch 上完成安全同步。"
        }
        guard !healthSamples.isEmpty else {
            return "先从完成安全配对的真实 Watch 同步健康数据。"
        }
        guard hasAppleHealthExportableSamples else {
            return "当前只有日总能量。它包含基础代谢，只保留在应用内，不写入 Apple Health。"
        }
        guard healthKitAuthorizationStatus.canExportAuthorizedData else {
            return "先在“设备”中允许 GalaxyCompanion 写入 Apple Health。"
        }
        return "已授权的样本会在手动同步完成后自动写入 Apple Health；无需保持 Watch 在线。"
    }

    /// Pulled data is never silently relabelled merely to fit a HealthKit
    /// type. Keep this visible whenever the Watch supplied a value that the
    /// iPhone intentionally retains only inside GalaxyCompanion.
    var appleHealthExclusionNotice: String? {
        let totalEnergyCount = healthSamples.filter { $0.metric == .totalCalories }.count
        let unsupportedCount = healthSamples.filter {
            switch $0.metric {
            case .totalCalories, .ibi, .hrv, .respiratoryRate, .skinTemperature:
                true
            default:
                false
            }
        }.count - totalEnergyCount

        var notices: [String] = []
        if totalEnergyCount > 0 {
            notices.append("\(totalEnergyCount) 条日总能量未写入 Apple Health（可能包含基础代谢，不能当作活动能量）。")
        }
        if unsupportedCount > 0 {
            notices.append("\(unsupportedCount) 条暂不具备安全 Apple Health 映射的记录仅保留在本应用。")
        }
        return notices.isEmpty ? nil : notices.joined(separator: " ")
    }

    /// Explains the Watch-side cache before a manual pull. This avoids making
    /// a successful empty batch look like a broken iPhone button.
    var watchLocalRecordingDetail: String {
        guard let capabilities else {
            return "连接 Watch 后会显示它是否已开始本地健康记录。"
        }
        if capabilities.isLocalHealthRecordingEnabled == false {
            return "Watch 尚未开启本地健康记录。请在 Watch 的 GalaxyCompanion 中点“启动”。"
        }
        guard let count = capabilities.localHealthSampleCount else {
            return "此 Watch 版本未报告本地记录数。手动同步会安全请求已有缓存。"
        }
        if count == 0 {
            return "Watch 已允许健康记录，但本地缓存目前为 0 条。Health Services 会按系统节奏分批保存；首次启用后请留出时间再手动同步。"
        }
        return "Watch 本地缓存有 \(count) 条记录，点击后会以增量方式拉取到 iPhone。"
    }

    func startDeviceDiscovery() {
        transport.startDiscovery()
    }

    func stopDeviceDiscovery() {
        transport.stop()
    }

    func requestSystemPairing() {
        transport.requestSystemPairing()
    }

    func synchronizeHealth() {
        // The same AppState is shared by all three tabs. A second tap from a
        // different tab must never replace a real in-flight pull with the
        // misleading "already waiting" failure seen in the old UI.
        guard !isSyncing else { return }
        guard let healthSyncService else {
            healthSyncStatus = .unavailable("无法打开 iPhone 本地健康数据仓库。")
            return
        }
        guard isConnected else {
            healthSyncStatus = .blocked(syncRequirementDetail)
            return
        }
        guard pairingStatus == .trustedForCurrentConnection,
              capabilities?.healthDataMode == .authenticatedMeasurement else {
            synchronizeAfterPairing = true
            healthSyncStatus = .blocked("正在验证当前 BLE 会话的系统安全配对；验证成功后会自动开始同步。")
            requestSystemPairing()
            return
        }
        guard canSynchronize else {
            healthSyncStatus = .blocked(syncRequirementDetail)
            return
        }

        synchronizeAfterPairing = false
        healthSyncStatus = .syncing
        Task { [weak self, healthSyncService] in
            do {
                let snapshot = try await healthSyncService.synchronize()
                guard let self else { return }
                healthSamples = snapshot.samples
                refreshSleepAnalysis()
                lastSyncAt = Date()
                retentionRecoveryCursor = nil
                retentionRecoveryNotice = nil
                healthSyncStatus = .synced(snapshot)
                await exportSyncedSamplesToAppleHealthIfPossible()
            } catch let error as BLEHealthSyncServiceError {
                guard let self else { return }
                if case .synchronizationAlreadyInProgress = error {
                    // The original request remains authoritative and owns
                    // the continuation. Leave its progress visible instead
                    // of presenting a false terminal failure.
                    return
                }
                if case .retentionGap(let cursor) = error {
                    retentionRecoveryCursor = cursor
                }
                healthSyncStatus = .failed(error.localizedDescription)
            } catch {
                self?.healthSyncStatus = .failed("健康同步未完成：\(error.localizedDescription)")
            }
        }
    }

    /// The caller must present a destructive-history explanation and call this
    /// only after the person explicitly confirms the Watch-provided boundary.
    func confirmRetentionRecovery() {
        guard let healthSyncService, let cursor = retentionRecoveryCursor else { return }
        healthSyncStatus = .syncing
        Task { [weak self, healthSyncService] in
            do {
                let snapshot = try await healthSyncService
                    .recoverFromConfirmedRetentionGap(earliestAvailableCursor: cursor)
                guard let self else { return }
                healthSamples = snapshot.samples
                refreshSleepAnalysis()
                retentionRecoveryCursor = nil
                retentionRecoveryNotice = "已保存可恢复同步起点；请在安全连接可用后手动同步。"
                // Saving a recovery cursor is not evidence that the Watch is
                // still connected or that this connection remains trusted.
                // Re-evaluate the normal runtime gate after the durable write
                // instead of optimistically advertising a ready state.
                healthSyncStatus = .blocked(syncRequirementDetail)
                refreshSyncAvailability()
            } catch {
                self?.healthSyncStatus = .failed("无法保存已确认的恢复起点：\(error.localizedDescription)")
            }
        }
    }

    func requestHealthKitAuthorization() {
        guard let healthKitExportService else { return }
        healthKitAuthorizationStatus = .checking

        Task { [weak self, healthKitExportService] in
            let status = await healthKitExportService.requestAuthorization()
            guard let self else { return }
            healthKitAuthorizationStatus = status
            await exportCachedSamplesToAppleHealthIfPossible()
        }
    }

    func exportToAppleHealth() {
        Task { [weak self] in
            await self?.exportCachedSamplesToAppleHealthIfPossible()
        }
    }

    /// A manual Watch pull is the user's explicit intent to update both local
    /// iPhone storage and Apple Health. Request HealthKit consent only when
    /// the system says it is needed, then export every safely mappable value.
    /// Unsupported values remain local and are surfaced in the dashboard.
    private func exportSyncedSamplesToAppleHealthIfPossible() async {
        guard !healthSamples.isEmpty else { return }
        guard let healthKitExportService else {
            healthKitExportStatus = .blocked("Apple Health 写入服务不可用。")
            return
        }

        switch healthKitAuthorizationStatus {
        case .needsAuthorization, .unknown:
            healthKitAuthorizationStatus = .checking
            healthKitAuthorizationStatus = await healthKitExportService.requestAuthorization()
        case .checking:
            healthKitAuthorizationStatus = await healthKitExportService.refreshAuthorization()
            if case .needsAuthorization = healthKitAuthorizationStatus {
                healthKitAuthorizationStatus = await healthKitExportService.requestAuthorization()
            } else if case .unknown = healthKitAuthorizationStatus {
                healthKitAuthorizationStatus = await healthKitExportService.requestAuthorization()
            }
        case .authorized, .partiallyAuthorized, .unavailable, .denied, .failed:
            break
        }
        await exportCachedSamplesToAppleHealthIfPossible()
    }

    private func exportCachedSamplesToAppleHealthIfPossible() async {
        guard let healthKitExportService else {
            healthKitExportStatus = .blocked("Apple Health 写入服务不可用。")
            return
        }
        guard transportMode == .hardware else {
            healthKitExportStatus = .blocked("模拟传输不会写入 Apple Health。")
            return
        }
        guard !healthSamples.isEmpty, hasAppleHealthExportableSamples else {
            healthKitExportStatus = .blocked(
                appleHealthExclusionNotice ?? "当前没有可安全写入 Apple Health 的健康记录。"
            )
            return
        }
        guard healthKitAuthorizationStatus.canExportAuthorizedData else {
            healthKitExportStatus = .blocked(appleHealthExportRequirementDetail)
            return
        }
        guard !isExporting else { return }

        healthKitExportStatus = .exporting
        let samples = healthSamples
        // The durable store is written only after the authenticated BLE sync
        // gate. Re-running this method is safe: HealthKit sync identifiers
        // and the local ledger make it idempotent.
        let result = await healthKitExportService.export(
            samples,
            dataMode: .authenticatedMeasurement
        )
        healthKitExportStatus = .result(result)
    }

    /// Re-runs the deterministic on-device sleep policy over the encrypted
    /// iPhone cache. It never contacts a Watch or Apple Health and never
    /// turns missing sensor coverage into a guessed sleep score.
    func analyzeLatestSleep() {
        refreshSleepAnalysis()
    }

    private var hasAppleHealthExportableSamples: Bool {
        AppleHealthCumulativeNormalizer.exportableSamples(from: healthSamples).contains { sample in
            if case .success = AppleHealthSampleMapper.map(sample) { return true }
            return false
        }
    }

    private func refreshSyncAvailability() {
        guard !isSyncing else { return }
        guard healthSyncService != nil else {
            healthSyncStatus = .unavailable("无法打开 iPhone 本地健康数据仓库。")
            return
        }
        guard !canSynchronize else {
            if case .synced = healthSyncStatus { return }
            healthSyncStatus = .ready
            return
        }
        if case .failed = healthSyncStatus { return }
        healthSyncStatus = .blocked(syncRequirementDetail)
    }

    private func continueSynchronizationAfterPairingIfReady() {
        guard synchronizeAfterPairing, canSynchronize else { return }
        synchronizeAfterPairing = false
        synchronizeHealth()
    }

    private func refreshHealthKitAuthorization() async {
        guard let healthKitExportService else { return }
        healthKitAuthorizationStatus = await healthKitExportService.refreshAuthorization()
    }

    private func loadCachedHealthSnapshot() async {
        guard let healthSyncService else { return }
        let snapshot = await healthSyncService.cachedSnapshot()
        healthSamples = snapshot.samples
        refreshSleepAnalysis()
        if !snapshot.samples.isEmpty {
            healthSyncStatus = .synced(snapshot)
        }
    }

    private func refreshSleepAnalysis() {
        sleepAnalysis = LocalSleepAnalyzer.analyze(samples: healthSamples)
    }

    private static func defaultTransport() -> any WatchTransport {
        CoreBluetoothWatchTransport()
    }
}

enum HealthSyncStatus: Equatable {
    case ready
    case syncing
    case synced(HealthSyncSnapshot)
    case unavailable(String)
    case blocked(String)
    case failed(String)

    var title: String {
        switch self {
        case .ready: "可以安全同步"
        case .syncing: "正在同步健康数据"
        case .synced(let snapshot):
            if snapshot.samples.isEmpty, snapshot.cursor == 0 {
                "Watch 暂无可同步记录"
            } else if snapshot.insertedSampleCount + snapshot.updatedSampleCount > 0 {
                "已更新 iPhone 本地数据"
            } else {
                "iPhone 本地数据已是最新"
            }
        case .unavailable: "健康同步不可用"
        case .blocked: "等待安全连接"
        case .failed: "同步需要处理"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            "手表将以 cursor 增量传输，iPhone 会去重并保留修订。"
        case .syncing:
            "正在从手表增量拉取并安全保存到 iPhone。"
        case .synced(let snapshot):
            if snapshot.samples.isEmpty, snapshot.cursor == 0 {
                "Watch 已响应同步请求，但没有返回本地健康记录。请先在 Watch 点“启动”并等待 Health Services 保存样本。"
            } else {
                "cursor \(snapshot.cursor) · 新增 \(snapshot.insertedSampleCount) · 修订 \(snapshot.updatedSampleCount) · 重复 \(snapshot.duplicateSampleCount)"
            }
        case .unavailable(let reason), .blocked(let reason), .failed(let reason):
            reason
        }
    }
}

enum HealthKitExportStatus: Equatable {
    case idle
    case exporting
    case result(HealthKitExportResult)
    case blocked(String)

    var title: String {
        switch self {
        case .idle: "尚未写入 Apple Health"
        case .exporting: "正在写入 Apple Health"
        case .result(.exported): "Apple Health 已更新"
        case .result(.partialFailure): "Apple Health 已部分更新"
        case .result(.failed): "Apple Health 写入失败"
        case .result(.blockedUntrustedData): "未写入未验证数据"
        case .result(.unavailable): "Apple Health 不可用"
        case .blocked: "等待可写入的数据"
        }
    }

    var detail: String {
        switch self {
        case .idle:
            return "同步到 iPhone 后，可由你主动选择写入已授权类型。"
        case .exporting:
            return "正在逐条写入；失败的样本会保留准确状态以便重试。"
        case .result(let result):
            switch result {
            case .exported(let report):
                return exportDetail(report)
            case .partialFailure(let report):
                return "\(exportDetail(report)) \(report.failures.count) 条需要处理。"
            case .failed(let report):
                return report.failures.first ?? "没有样本被写入。"
            case .blockedUntrustedData:
                return "只有当前安全连接同步的认证测量数据才能写入。"
            case .unavailable(let reason):
                return reason
            }
        case .blocked(let reason):
            return reason
        }
    }

    private func exportDetail(_ report: HealthKitExportReport) -> String {
        var detail = "已写入 \(report.writtenSampleCount) 条、移除 \(report.removedSampleCount) 条修正前数据；此前已写入 \(report.previouslyWrittenSampleCount) 条。"
        if report.rejectedSampleCount > 0 {
            detail += " \(report.rejectedSampleCount) 条因类型、单位或质量不安全而仅保留在本应用。"
        }
        return detail
    }
}

private extension HealthKitAuthorizationState {
    var canExportAuthorizedData: Bool {
        switch self {
        case .authorized, .partiallyAuthorized:
            true
        case .checking, .unavailable, .needsAuthorization, .denied, .unknown, .failed:
            false
        }
    }
}
