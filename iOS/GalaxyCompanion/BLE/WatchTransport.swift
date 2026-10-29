import Foundation

enum WatchTransportMode: Equatable {
    case hardware
    case simulated

    var title: String {
        switch self {
        case .hardware:
            "真实 BLE 手表"
        case .simulated:
            "模拟手表"
        }
    }

    var detail: String {
        switch self {
        case .hardware:
            "通过 GalaxyCompanion 自有 GATT 服务连接真实 Galaxy Watch。"
        case .simulated:
            "仅用于 iOS 模拟器中的界面与协议流程验证，不访问蓝牙硬件。"
        }
    }
}

/// Business-facing connection state. CoreBluetooth types never cross this boundary.
enum WatchTransportState: Equatable {
    case waitingForBluetooth
    case bluetoothUnavailable(String)
    case readyToScan
    case scanning
    case connecting(String?)
    case discoveringServices(String?)
    case connected(String?)
    case failed(String)
    case stopped

    var title: String {
        switch self {
        case .waitingForBluetooth:
            "正在初始化蓝牙"
        case .bluetoothUnavailable:
            "蓝牙不可用"
        case .readyToScan:
            "准备扫描"
        case .scanning:
            "正在搜索 GalaxyCompanion 手表服务"
        case .connecting(let name):
            "正在连接 \(name ?? "手表")"
        case .discoveringServices(let name):
            "正在验证 \(name ?? "手表")"
        case .connected(let name):
            "已连接 \(name ?? "Galaxy Watch")"
        case .failed:
            "连接失败"
        case .stopped:
            "搜索已停止"
        }
    }

    var detail: String {
        switch self {
        case .waitingForBluetooth:
            "正在等待 CoreBluetooth 就绪。"
        case .bluetoothUnavailable(let reason):
            reason
        case .readyToScan:
            "仅搜索 GalaxyCompanion 自有的 BLE 服务，不访问三星私有协议。"
        case .scanning:
            "请确保 Watch 端 GalaxyCompanion 已完成蓝牙授权并启动广播。"
        case .connecting:
            "已发现候选设备，正在建立 BLE 连接。"
        case .discoveringServices:
            "正在确认 GATT 服务和基础特征。"
        case .connected:
            "BLE 链路和设备能力读取已就绪；健康数据传输仍需通过配对验证。"
        case .failed(let reason):
            reason
        case .stopped:
            "未主动保持或恢复当前连接。"
        }
    }
}

enum WatchPairingStatus: Equatable {
    case notChecked
    case requestingSystemPairing
    case trustedForCurrentConnection
    case failed(String)

    var title: String {
        switch self {
        case .notChecked: "尚未验证"
        case .requestingSystemPairing: "等待系统配对"
        case .trustedForCurrentConnection: "当前连接已验证"
        case .failed: "配对验证失败"
        }
    }

    var detail: String {
        switch self {
        case .notChecked:
            "读取受保护特征以请求 iOS 与 Watch 系统完成加密配对。"
        case .requestingSystemPairing:
            "请完成系统蓝牙配对提示；若没有弹窗，完成后再次验证。"
        case .trustedForCurrentConnection:
            "当前连接已通过系统加密与 MITM 保护校验；健康传输仍待真机 PoC。"
        case .failed(let reason):
            reason
        }
    }
}

/// Explicit business-level events for the basic-health GATT channel. These
/// events never expose CoreBluetooth characteristic objects to the app layer.
enum HealthSyncTransportEvent: Equatable {
    case requestSent(afterCursor: Int64, requestID: UUID)
    case batchReceived(HealthSyncBatch)
    case failed(String)
}

@MainActor
protocol WatchTransport: AnyObject {
    var mode: WatchTransportMode { get }
    var state: WatchTransportState { get }
    var onStateChange: ((WatchTransportState) -> Void)? { get set }
    var onCapabilitiesChange: ((WatchCapabilities) -> Void)? { get set }
    var onPairingStatusChange: ((WatchPairingStatus) -> Void)? { get set }
    var onHealthSyncEvent: ((HealthSyncTransportEvent) -> Void)? { get set }

    func startDiscovery()
    func stop()
    func requestSystemPairing()
    func requestHealthSync(
        requestID: UUID,
        after cursor: Int64,
        maximumSampleCount: UInt16
    )
}
