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
    private let healthKitExportService: HealthKitExportService?
    private(set) var transportMode: WatchTransportMode
    private(set) var connectionState: WatchTransportState
    private(set) var capabilities: WatchCapabilities?
    private(set) var healthSyncStatus: HealthSyncStatus
    private(set) var healthKitAuthorizationStatus: HealthKitAuthorizationState

    init(transport: (any WatchTransport)? = nil) {
        let selectedTransport = transport ?? Self.defaultTransport()
        self.transport = selectedTransport
        self.transportMode = selectedTransport.mode
        self.connectionState = selectedTransport.state
        do {
            self.healthKitExportService = try HealthKitExportService()
            self.healthKitAuthorizationStatus = .checking
        } catch {
            self.healthKitExportService = nil
            self.healthKitAuthorizationStatus = .unavailable(
                "无法初始化 Apple Health 写入记录：\(error.localizedDescription)"
            )
        }
        self.healthSyncStatus = .blocked("健康同步将在认证配对与真机连接验证完成后开放；当前不会生成或保存模拟健康数据。")
        selectedTransport.onStateChange = { [weak self] state in
            self?.connectionState = state
        }
        selectedTransport.onCapabilitiesChange = { [weak self] capabilities in
            self?.capabilities = capabilities
        }
        if healthKitExportService != nil {
            Task { [weak self] in
                await self?.refreshHealthKitAuthorization()
            }
        }
    }

    func startDeviceDiscovery() {
        transport.startDiscovery()
    }

    func stopDeviceDiscovery() {
        transport.stop()
    }

    func requestHealthKitAuthorization() {
        guard let healthKitExportService else { return }
        healthKitAuthorizationStatus = .checking

        Task { [weak self] in
            let status = await healthKitExportService.requestAuthorization()
            self?.healthKitAuthorizationStatus = status
        }
    }

    private func refreshHealthKitAuthorization() async {
        guard let healthKitExportService else { return }
        healthKitAuthorizationStatus = await healthKitExportService.refreshAuthorization()
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
        case .ready: "基础健康数据待同步"
        case .syncing: "正在同步基础健康数据"
        case .synced(let snapshot): "已同步 \(snapshot.insertedSampleCount) 条样本"
        case .unavailable: "基础健康同步尚未接入"
        case .blocked: "真实健康同步已安全禁用"
        case .failed: "同步失败"
        }
    }

    var detail: String {
        switch self {
        case .ready:
            "使用版本化 cursor、批次和 UUID 去重；未写入 Apple Health。"
        case .syncing:
            "正在从手表增量拉取并保存到 iPhone 本地仓库。"
        case .synced(let snapshot):
            "cursor: \(snapshot.cursor)，重复样本: \(snapshot.duplicateSampleCount)。未写入 Apple Health。"
        case .unavailable(let reason), .blocked(let reason), .failed(let reason):
            reason
        }
    }
}
