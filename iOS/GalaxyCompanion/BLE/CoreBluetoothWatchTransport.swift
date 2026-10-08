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
    private var shouldDiscover = false

    private(set) var state: WatchTransportState = .waitingForBluetooth {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((WatchTransportState) -> Void)?

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
        centralManager.stopScan()
        if let candidate {
            centralManager.cancelPeripheralConnection(candidate)
        }
        self.candidate = nil
        state = .stopped
    }

    private func beginScanIfPossible() {
        guard centralManager.state == .poweredOn else {
            state = bluetoothUnavailableState(for: centralManager.state)
            return
        }

        candidate = nil
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
        state = .failed(error?.localizedDescription ?? "无法建立与手表的 BLE 连接。")
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        candidate = nil
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
            state = .failed(error?.localizedDescription ?? "无法发现 Watch GATT 服务。")
            return
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == Contract.service }) else {
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
            state = .failed(error?.localizedDescription ?? "无法发现 Watch GATT 特征。")
            return
        }

        let discovered = Set(characteristics.map(\.uuid))
        let required: Set<CBUUID> = [Contract.capabilities, Contract.syncControl, Contract.syncData]
        guard required.isSubset(of: discovered) else {
            state = .failed("Watch GATT 服务缺少 GalaxyCompanion 协议所需特征。")
            return
        }

        if let dataCharacteristic = characteristics.first(where: { $0.uuid == Contract.syncData }) {
            peripheral.setNotifyValue(true, for: dataCharacteristic)
        }
        state = .connected(peripheral.name)
    }
}
