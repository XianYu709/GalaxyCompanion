import SwiftUI

struct ContentView: View {
    let appState: AppState

    var body: some View {
        TabView {
            OverviewView(appState: appState)
                .tabItem { Label("概览", systemImage: "circle.dotted") }
            HealthDashboardView(appState: appState)
                .tabItem { Label("健康", systemImage: "heart.text.square") }
            DeviceView(appState: appState)
                .tabItem { Label("设备", systemImage: "applewatch") }
        }
        .tint(NightCurrent.mint)
        .preferredColorScheme(.dark)
        .toolbarBackground(NightCurrent.ink.opacity(0.96), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .background(NightCurrent.ink.ignoresSafeArea())
    }
}

private struct OverviewView: View {
    let appState: AppState

    var body: some View {
        ZStack {
            NightCurrentBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    CurrentSectionHeader(
                        eyebrow: "GalaxyCompanion",
                        title: "手表，安心在身边。",
                        detail: "只连接你安装了 GalaxyCompanion 的 Watch。"
                    )

                    CurrentCard(title: "当前连接", symbol: "wave.3.right", tint: statusTint) {
                        HStack(alignment: .center, spacing: 18) {
                            ConnectionOrbit(
                                connection: appState.connectionState,
                                pairing: appState.pairingStatus
                            )
                            VStack(alignment: .leading, spacing: 8) {
                                CurrentStatusPill(
                                    title: appState.connectionState.title,
                                    tint: statusTint
                                )
                                Text(connectionHeadline)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(NightCurrent.fog)
                                Text(connectionDetail)
                                    .font(.footnote)
                                    .foregroundStyle(NightCurrent.muted)
                            }
                        }
                    }

                    CurrentPrimaryButton(
                        primaryTitle,
                        symbol: primarySymbol,
                        tint: primaryTint,
                        isLoading: appState.isSyncing || isConnecting,
                        action: primaryAction
                    )
                    .disabled(isConnecting || appState.isSyncing)
                    .opacity(isConnecting || appState.isSyncing ? 0.75 : 1)

                    CurrentCard(title: "数据状态", symbol: "arrow.triangle.2.circlepath", tint: syncTint) {
                        Text(appState.healthSyncStatus.title)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(NightCurrent.fog)
                        Text(appState.healthSyncStatus.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        if let notice = appState.retentionRecoveryNotice {
                            Label(notice, systemImage: "bookmark.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(NightCurrent.amber)
                        }
                        if let lastSyncAt = appState.lastSyncAt {
                            Label(
                                "本次同步：\(lastSyncAt.formatted(date: .abbreviated, time: .shortened))",
                                systemImage: "clock"
                            )
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(NightCurrent.blue)
                        }
                    }

                    CurrentCard(title: "安全边界", symbol: "lock.shield", tint: pairingTint) {
                        Text(appState.pairingStatus.title)
                            .font(.headline)
                            .foregroundStyle(NightCurrent.fog)
                        Text(appState.pairingStatus.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        Label("健康数据只在当前受保护连接中同步", systemImage: "checkmark.shield")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(NightCurrent.mint)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                // Reserve the translucent system tab bar so the last action
                // remains visible and reachable on every phone size.
                .padding(.bottom, 116)
            }
        }
        // TabView may otherwise size a tab to its ScrollView's content on
        // compact simulator/window configurations, leaving letterboxed space.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isConnecting: Bool {
        switch appState.connectionState {
        case .scanning, .connecting, .discoveringServices: true
        default: false
        }
    }

    private var connectionHeadline: String {
        if appState.pairingStatus == .trustedForCurrentConnection {
            return "这条连接已安全验证"
        }
        return appState.connectionState.title
    }

    private var connectionDetail: String {
        appState.pairingStatus == .trustedForCurrentConnection
            ? "可安全同步的状态仍需 Watch 确认健康数据权限。"
            : appState.connectionState.detail
    }

    private var primaryTitle: String {
        if appState.isSyncing { return "正在同步，请稍候" }
        if !appState.isConnected { return "搜索我的手表" }
        if appState.pairingStatus != .trustedForCurrentConnection { return "验证安全配对" }
        if appState.capabilities?.healthDataMode != .authenticatedMeasurement {
            return "重新验证数据权限"
        }
        return "同步到 iPhone"
    }

    private var primarySymbol: String {
        if !appState.isConnected { return "magnifyingglass" }
        if appState.pairingStatus != .trustedForCurrentConnection { return "lock.badge.clock" }
        return "arrow.down.circle.fill"
    }

    private var primaryTint: Color {
        appState.canSynchronize ? NightCurrent.mint : (appState.isConnected ? NightCurrent.amber : NightCurrent.blue)
    }

    private func primaryAction() {
        if !appState.isConnected {
            appState.startDeviceDiscovery()
        } else if appState.pairingStatus != .trustedForCurrentConnection ||
                    appState.capabilities?.healthDataMode != .authenticatedMeasurement {
            appState.requestSystemPairing()
        } else {
            appState.synchronizeHealth()
        }
    }

    private var statusTint: Color {
        connectionTint(for: appState.connectionState, pairing: appState.pairingStatus)
    }

    private var pairingTint: Color {
        appState.pairingStatus == .trustedForCurrentConnection ? NightCurrent.mint : NightCurrent.amber
    }

    private var syncTint: Color {
        switch appState.healthSyncStatus {
        case .ready, .synced: NightCurrent.mint
        case .syncing: NightCurrent.blue
        case .failed: NightCurrent.rose
        case .blocked, .unavailable: NightCurrent.amber
        }
    }
}

private struct DeviceView: View {
    let appState: AppState
    @State private var showsRetentionRecoveryConfirmation = false

    var body: some View {
        ZStack {
            NightCurrentBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    CurrentSectionHeader(
                        eyebrow: "设备与权限",
                        title: "连接的每一步，都看得见。",
                        detail: "这里显示必要的设备和同步诊断，不显示健康原始记录。"
                    )

                    CurrentCard(
                        title: "BLE 连接",
                        symbol: "antenna.radiowaves.left.and.right",
                        tint: connectionTint(
                            for: appState.connectionState,
                            pairing: appState.pairingStatus
                        )
                    ) {
                        KeyValueRow(label: "状态", value: appState.connectionState.title)
                        Text(appState.connectionState.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        Button(appState.isConnected ? "停止搜索与连接" : "搜索我的手表") {
                            appState.isConnected ? appState.stopDeviceDiscovery() : appState.startDeviceDiscovery()
                        }
                        .buttonStyle(.bordered)
                        .tint(NightCurrent.blue)
                        .disabled(appState.isSyncing)
                    }

                    CurrentCard(title: "系统安全配对", symbol: "lock.shield", tint: pairingTint) {
                        KeyValueRow(label: "当前会话", value: appState.pairingStatus.title)
                        Text(appState.pairingStatus.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        Button("请求 / 验证蓝牙配对") { appState.requestSystemPairing() }
                            .buttonStyle(.borderedProminent)
                            .tint(pairingTint)
                            .disabled(!appState.isConnected || appState.isSyncing)
                    }

                    CurrentCard(title: "Watch 身份与能力", symbol: "cpu", tint: NightCurrent.blue) {
                        if let capabilities = appState.capabilities {
                            KeyValueRow(label: "型号", value: capabilities.identity.model)
                            KeyValueRow(label: "Wear OS", value: capabilities.identity.wearOSVersion)
                            KeyValueRow(label: "固件", value: capabilities.identity.firmwareVersion)
                            KeyValueRow(label: "数据权限", value: capabilities.healthDataMode.deviceLabel)
                            if let recordingEnabled = capabilities.isLocalHealthRecordingEnabled {
                                KeyValueRow(
                                    label: "本地健康记录",
                                    value: recordingEnabled ? "已开启" : "未开启"
                                )
                            }
                            if let sampleCount = capabilities.localHealthSampleCount {
                                KeyValueRow(label: "可同步本地记录", value: "\(sampleCount) 条")
                            }
                            Divider().overlay(Color.white.opacity(0.10))
                            Text("正在采集")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(NightCurrent.fog)
                            Text(capabilities.enabled.sorted { $0.rawValue < $1.rawValue }.map(\.deviceLabel).joined(separator: " · "))
                                .font(.footnote)
                                .foregroundStyle(NightCurrent.muted)
                            if !capabilities.passiveDataTypeNames.isEmpty {
                                Divider().overlay(Color.white.opacity(0.10))
                                Label(
                                    "Health Services 被动能力（\(capabilities.passiveDataTypeNames.count) 项）",
                                    systemImage: "sensor.tag.radiowaves.forward"
                                )
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(NightCurrent.blue)
                                Text(capabilities.passiveDataTypeDisplay)
                                    .font(.caption)
                                    .foregroundStyle(NightCurrent.muted)
                                Text("这是本机实时报告的系统能力；只有具备明确数据含义与安全映射的项目才会自动采集。血氧与压力需要独立三星传感器 PoC。")
                                    .font(.caption2)
                                    .foregroundStyle(NightCurrent.muted.opacity(0.9))
                            }
                        } else {
                            EmptyDeviceDetail()
                        }
                    }

                    CurrentCard(title: "Apple Health", symbol: "heart.text.square", tint: NightCurrent.mint) {
                        Text(appState.healthKitAuthorizationStatus.title)
                            .font(.headline)
                            .foregroundStyle(NightCurrent.fog)
                        Text(appState.healthKitAuthorizationStatus.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        if appState.healthKitAuthorizationStatus.canRequestAuthorization {
                            Button("选择允许写入的健康数据") { appState.requestHealthKitAuthorization() }
                                .buttonStyle(.bordered)
                                .tint(NightCurrent.mint)
                        }
                        Divider().overlay(Color.white.opacity(0.10))
                        Text(appState.healthKitExportStatus.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NightCurrent.fog)
                        Text(appState.healthKitExportStatus.detail)
                            .font(.footnote)
                            .foregroundStyle(NightCurrent.muted)
                        if let exclusionNotice = appState.appleHealthExclusionNotice {
                            Label(exclusionNotice, systemImage: "info.circle.fill")
                                .font(.caption)
                                .foregroundStyle(NightCurrent.amber)
                        }
                        if !appState.canExportToAppleHealth {
                            Text(appState.appleHealthExportRequirementDetail)
                                .font(.caption)
                                .foregroundStyle(NightCurrent.muted)
                        }
                    }

                    CurrentCard(title: "同步诊断", symbol: "stethoscope", tint: diagnosticTint) {
                        KeyValueRow(label: "传输", value: appState.transportMode.title)
                        Text(appState.healthSyncStatus.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(NightCurrent.fog)
                        Text(appState.healthSyncStatus.detail)
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(NightCurrent.muted)
                        if let notice = appState.retentionRecoveryNotice {
                            Divider().overlay(Color.white.opacity(0.10))
                            Label(notice, systemImage: "bookmark.fill")
                                .font(.footnote.weight(.medium))
                                .foregroundStyle(NightCurrent.amber)
                        }
                        if let cursor = appState.retentionRecoveryCursor {
                            Divider().overlay(Color.white.opacity(0.10))
                            Text("Watch 已因容量限制淘汰一段未同步历史。继续后，cursor \(cursor) 之前的数据无法从 Watch 恢复。")
                                .font(.footnote)
                                .foregroundStyle(NightCurrent.amber)
                            Button("确认从可恢复边界继续") {
                                showsRetentionRecoveryConfirmation = true
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(NightCurrent.amber)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 28)
                .padding(.bottom, 116)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("确认继续同步？", isPresented: $showsRetentionRecoveryConfirmation) {
            Button("取消", role: .cancel) {}
            Button("确认并设置恢复起点", role: .destructive) {
                appState.confirmRetentionRecovery()
            }
        } message: {
            Text("这不会伪造或补回已从 Watch 缓存淘汰的历史。系统会将 iPhone 同步起点移到 Watch 报告的可恢复边界，之后请再次主动同步。")
        }
    }

    private var pairingTint: Color {
        appState.pairingStatus == .trustedForCurrentConnection ? NightCurrent.mint : NightCurrent.amber
    }

    private var diagnosticTint: Color {
        switch appState.healthSyncStatus {
        case .failed: NightCurrent.rose
        case .blocked, .unavailable: NightCurrent.amber
        case .ready, .synced: NightCurrent.mint
        case .syncing: NightCurrent.blue
        }
    }
}

struct KeyValueRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label)
                .font(.caption)
                .foregroundStyle(NightCurrent.muted)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline.monospaced())
                .foregroundStyle(NightCurrent.fog)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct EmptyDeviceDetail: View {
    var body: some View {
        ContentUnavailableView {
            Label("尚未读取设备信息", systemImage: "applewatch.slash")
        } description: {
            Text("连接自有 GATT 服务后，会在这里显示型号、系统版本和公开能力。")
        }
        .foregroundStyle(NightCurrent.muted)
    }
}

private func connectionTint(
    for state: WatchTransportState,
    pairing: WatchPairingStatus
) -> Color {
    switch state {
    case .connected:
        // A BLE link alone is not a verified session. Mint is reserved for
        // the current system-paired connection, so an unpaired link remains
        // visibly actionable rather than falsely signalling success.
        return pairing == .trustedForCurrentConnection ? NightCurrent.mint : NightCurrent.amber
    case .scanning, .connecting, .discoveringServices: return NightCurrent.blue
    case .failed, .bluetoothUnavailable: return NightCurrent.rose
    case .waitingForBluetooth, .readyToScan, .stopped: return NightCurrent.amber
    }
}

private extension WatchCapability {
    var deviceLabel: String {
        switch self {
        case .heartRate: "心率"
        case .steps: "步数"
        case .calories: "卡路里"
        case .distance: "距离"
        case .floors: "楼层"
        case .spo2: "血氧"
        case .skinTemperature: "皮温"
        case .respiratoryRate: "呼吸率"
        case .ibi: "IBI"
        case .ppg: "PPG"
        case .accelerometer: "加速度"
        case .eda: "EDA"
        case .bia: "BIA"
        case .mfBia: "MF-BIA"
        case .ecg: "ECG"
        case .nfcReader: "NFC Reader"
        case .nfcHce: "NFC HCE"
        }
    }
}

private extension WatchCapabilities {
    var passiveDataTypeDisplay: String {
        passiveDataTypeNames
            .map { name in
                switch name {
                case "HeartRate": "心率"
                case "Daily Steps": "日累计步数"
                case "Steps": "步数增量"
                case "Daily Calories": "日总能量"
                case "Calories": "能量增量"
                case "Daily Distance": "日累计距离"
                case "Distance": "距离增量"
                case "Daily Floors": "日累计楼层"
                case "Floors": "楼层增量"
                case "Elevation Gain": "爬升"
                case "Daily Elevation Gain": "日累计爬升"
                case "Walking Steps": "步行步数"
                case "Running Steps": "跑步步数"
                case "Speed": "速度"
                case "Location": "位置"
                default: name
                }
            }
            .sorted()
            .joined(separator: " · ")
    }
}

private extension HealthDataMode {
    var deviceLabel: String {
        switch self {
        case .authenticatedMeasurement: "当前会话已认证"
        case .unavailable: "尚未认证"
        case .developmentSynthetic: "开发合成数据（不可写入）"
        }
    }
}

#Preview {
    ContentView(appState: AppState())
}
