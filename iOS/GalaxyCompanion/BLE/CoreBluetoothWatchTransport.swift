@preconcurrency import CoreBluetooth
import Foundation

/// CoreBluetooth implementation for the app-owned GalaxyCompanion GATT service.
@MainActor
final class CoreBluetoothWatchTransport: NSObject, WatchTransport {
    @MainActor
    private enum Contract {
        static let service = CBUUID(string: "2B0D0001-4F31-4BB2-8F63-891BB1BD0001")
        static let capabilities = CBUUID(string: "2B0D0002-4F31-4BB2-8F63-891BB1BD0001")
        static let syncControl = CBUUID(string: "2B0D0003-4F31-4BB2-8F63-891BB1BD0001")
        static let syncData = CBUUID(string: "2B0D0004-4F31-4BB2-8F63-891BB1BD0001")
    }

    private var centralManager: CBCentralManager!
    private var candidate: CBPeripheral?
    private var syncControlCharacteristic: CBCharacteristic?
    private var syncDataCharacteristic: CBCharacteristic?
    private var syncDataNotificationsEnabled = false
    private var syncPacketAssembler = GATTHealthSyncPacketAssembler()
    private var healthSyncRequestInFlight = false
    private var expectedHealthSyncRequestID: UUID?
    private var shouldDiscover = false
    // Kept false until an authenticated pairing/session design exists and has
    // been verified on physical devices. BLE connection alone is not trust.
    private let physicalHealthTransferEnabled = false

    let mode: WatchTransportMode = .hardware

    private(set) var state: WatchTransportState = .waitingForBluetooth {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((WatchTransportState) -> Void)?
    var onCapabilitiesChange: ((WatchCapabilities) -> Void)?
    var onHealthSyncEvent: ((HealthSyncTransportEvent) -> Void)?

    override init() {
        super.init()
        centralManager = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: true]
        )
    }

    func startDiscovery() {
        shouldDiscover = true
        beginScanIfPossible()
    }

    func stop() {
        shouldDiscover = false
        failPendingHealthSync("健康同步已取消：手表连接已停止。")
        centralManager.stopScan()
        if let candidate {
            centralManager.cancelPeripheralConnection(candidate)
        }
        self.candidate = nil
        syncControlCharacteristic = nil
        syncDataCharacteristic = nil
        syncDataNotificationsEnabled = false
        syncPacketAssembler.reset()
        state = .stopped
    }

    func requestHealthSync(requestID: UUID, after cursor: Int64, maximumSampleCount: UInt16) {
        guard physicalHealthTransferEnabled else {
            onHealthSyncEvent?(
                .failed("真实手表健康传输已禁用：认证配对尚未设计并验证。")
            )
            return
        }
        guard let candidate, let syncControlCharacteristic, syncDataNotificationsEnabled else {
            onHealthSyncEvent?(.failed("基础健康同步通道尚未就绪，请先完成手表连接。"))
            return
        }
        guard cursor >= 0,
                maximumSampleCount > 0,
                maximumSampleCount <= UInt16(HealthSyncLimits.maximumSampleCount) else {
            onHealthSyncEvent?(.failed("健康同步请求超出协议允许的 cursor 或样本数范围。"))
            return
        }
        guard !healthSyncRequestInFlight else {
            onHealthSyncEvent?(.failed("已有健康同步请求正在等待手表响应。"))
            return
        }

        do {
            let request = HealthSyncRequest(
                requestID: requestID,
                afterCursor: cursor,
                maximumSampleCount: maximumSampleCount
            )
            let requestData = try ProtocolCodec.encode(request)
            syncPacketAssembler.reset()
            healthSyncRequestInFlight = true
            expectedHealthSyncRequestID = requestID
            candidate.writeValue(requestData, for: syncControlCharacteristic, type: .withResponse)
            onHealthSyncEvent?(.requestSent(afterCursor: cursor, requestID: requestID))
        } catch {
            if healthSyncRequestInFlight {
                failPendingHealthSync("无法编码健康同步请求：\(error.localizedDescription)")
            } else {
                onHealthSyncEvent?(.failed("无法编码健康同步请求：\(error.localizedDescription)"))
            }
        }
    }

    private func beginScanIfPossible() {
        guard centralManager.state == .poweredOn else {
            state = bluetoothUnavailableState(for: centralManager.state)
            return
        }

        candidate = nil
        syncControlCharacteristic = nil
        syncDataCharacteristic = nil
        syncDataNotificationsEnabled = false
        syncPacketAssembler.reset()
        failPendingHealthSync("无法建立与手表的 BLE 连接。")
        centralManager.stopScan()
        centralManager.scanForPeripherals(
            withServices: [Contract.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        state = .scanning
    }

    private func bluetoothUnavailableState(for state: CBManagerState) -> WatchTransportState {
        switch state {
        case .unknown, .resetting:
            .waitingForBluetooth
        case .unsupported:
            .bluetoothUnavailable("此 iPhone 不支持所需的蓝牙 LE 能力。")
        case .unauthorized:
            .bluetoothUnavailable("蓝牙权限未授予。请在系统设置中允许 GalaxyCompanion 使用蓝牙。")
        case .poweredOff:
            .bluetoothUnavailable("蓝牙已关闭。打开蓝牙后可重新搜索手表。")
        case .poweredOn:
            .readyToScan
        @unknown default:
            .bluetoothUnavailable("CoreBluetooth 返回了未知状态。")
        }
    }
}

extension CoreBluetoothWatchTransport: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            if shouldDiscover {
                beginScanIfPossible()
            } else {
                state = .readyToScan
            }
        } else {
            failPendingHealthSync("蓝牙连接不可用，已取消健康同步。")
            state = bluetoothUnavailableState(for: central.state)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard candidate == nil else { return }

        central.stopScan()
        candidate = peripheral
        peripheral.delegate = self
        state = .connecting(peripheral.name)
        central.connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state = .discoveringServices(peripheral.name)
        peripheral.discoverServices([Contract.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        candidate = nil
        syncControlCharacteristic = nil
        syncDataCharacteristic = nil
        syncDataNotificationsEnabled = false
        syncPacketAssembler.reset()
        failPendingHealthSync(error?.localizedDescription ?? "无法建立与手表的 BLE 连接。")
        state = .failed(error?.localizedDescription ?? "无法建立与手表的 BLE 连接。")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        candidate = nil
        syncControlCharacteristic = nil
        syncDataCharacteristic = nil
        syncDataNotificationsEnabled = false
        syncPacketAssembler.reset()
        failPendingHealthSync(error?.localizedDescription ?? "手表连接已断开。")
        if shouldDiscover {
            beginScanIfPossible()
        } else {
            state = .failed(error?.localizedDescription ?? "手表连接已断开。")
        }
    }
}

extension CoreBluetoothWatchTransport: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else {
            failPendingHealthSync(error?.localizedDescription ?? "无法发现 Watch GATT 服务。")
            state = .failed(error?.localizedDescription ?? "无法发现 Watch GATT 服务。")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Contract.service }) else {
            failPendingHealthSync("发现的设备未提供 GalaxyCompanion GATT 服务。")
            state = .failed("发现的设备未提供 GalaxyCompanion GATT 服务。")
            return
        }
        peripheral.discoverCharacteristics(
            [Contract.capabilities, Contract.syncControl, Contract.syncData],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else {
            failPendingHealthSync(error?.localizedDescription ?? "无法发现 Watch GATT 特征。")
            state = .failed(error?.localizedDescription ?? "无法发现 Watch GATT 特征。")
            return
        }

        let discovered = Set(characteristics.map(\.uuid))
        let required: Set<CBUUID> = [Contract.capabilities, Contract.syncControl, Contract.syncData]
        guard required.isSubset(of: discovered) else {
            failPendingHealthSync("Watch GATT 服务缺少 GalaxyCompanion 协议所需特征。")
            state = .failed("Watch GATT 服务缺少 GalaxyCompanion 协议所需特征。")
            return
        }

        syncControlCharacteristic = characteristics.first(where: { $0.uuid == Contract.syncControl })
        syncDataCharacteristic = characteristics.first(where: { $0.uuid == Contract.syncData })
        guard let capabilitiesCharacteristic = characteristics.first(where: { $0.uuid == Contract.capabilities }) else {
            failPendingHealthSync("Watch GATT 服务未返回能力特征。")
            state = .failed("Watch GATT 服务未返回能力特征。")
            return
        }
        peripheral.readValue(for: capabilitiesCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if characteristic.uuid == Contract.capabilities {
            guard error == nil, let value = characteristic.value else {
                failPendingHealthSync(error?.localizedDescription ?? "无法读取 Watch 能力信息。")
                state = .failed(error?.localizedDescription ?? "无法读取 Watch 能力信息。")
                return
            }

            do {
                let capabilities = try ProtocolCodec.decode(WatchCapabilities.self, from: value)
                onCapabilitiesChange?(capabilities)
                if let syncDataCharacteristic {
                    peripheral.setNotifyValue(true, for: syncDataCharacteristic)
                } else {
                    failPendingHealthSync("Watch GATT 服务未返回健康同步数据特征。")
                    state = .failed("Watch GATT 服务未返回健康同步数据特征。")
                }
            } catch {
                failPendingHealthSync("Watch 能力信息格式无效：\(error.localizedDescription)")
                state = .failed("Watch 能力信息格式无效：\(error.localizedDescription)")
            }
            return
        }

        guard characteristic.uuid == Contract.syncData else { return }
        guard error == nil, let value = characteristic.value else {
            failPendingHealthSync(error?.localizedDescription ?? "未收到完整的健康同步数据。")
            return
        }

        do {
            let packet = try GATTHealthSyncPacketCodec.decode(value)
            guard let batchData = try syncPacketAssembler.append(packet) else { return }
            let batch = try ProtocolCodec.decode(HealthSyncBatch.self, from: batchData)
            guard batch.protocolVersion == ProtocolCodec.currentVersion else {
                throw SynchronizationError.incompatibleProtocolVersion(batch.protocolVersion)
            }
            guard batch.sequence == packet.sequence else {
                throw GATTHealthSyncPacketError.unexpectedTransfer
            }
            guard healthSyncRequestInFlight,
                    batch.requestID == expectedHealthSyncRequestID else {
                throw GATTHealthSyncPacketError.unexpectedTransfer
            }
            healthSyncRequestInFlight = false
            expectedHealthSyncRequestID = nil
            onHealthSyncEvent?(.batchReceived(batch))
        } catch {
            failPendingHealthSync("健康同步数据格式无效：\(error.localizedDescription)")
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Contract.syncData else { return }
        guard error == nil, characteristic.isNotifying else {
            failPendingHealthSync(error?.localizedDescription ?? "无法订阅 Watch 健康同步数据。")
            state = .failed(error?.localizedDescription ?? "无法订阅 Watch 健康同步数据。")
            return
        }
        syncDataNotificationsEnabled = true
        state = .connected(peripheral.name)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard characteristic.uuid == Contract.syncControl, let error else { return }
        failPendingHealthSync("手表拒绝健康同步请求：\(error.localizedDescription)")
    }
}

private extension CoreBluetoothWatchTransport {
    func failPendingHealthSync(_ reason: String) {
        guard healthSyncRequestInFlight else { return }
        healthSyncRequestInFlight = false
        expectedHealthSyncRequestID = nil
        syncPacketAssembler.reset()
        onHealthSyncEvent?(.failed(reason))
    }
}
