import Foundation

/// Deterministic transport used only by the iOS Simulator. It exercises the
/// same connection and capability boundary as the hardware transport without
/// pretending that the simulator has Bluetooth LE hardware.
@MainActor
final class DebugWatchTransport: WatchTransport {
    let mode: WatchTransportMode = .simulated

    private(set) var state: WatchTransportState = .readyToScan {
        didSet { onStateChange?(state) }
    }

    var onStateChange: ((WatchTransportState) -> Void)?
    var onCapabilitiesChange: ((WatchCapabilities) -> Void)?
    var onHealthSyncEvent: ((HealthSyncTransportEvent) -> Void)?

    func startDiscovery() {
        state = .scanning
        state = .connecting("GalaxyCompanion Debug Watch")
        onCapabilitiesChange?(Self.capabilities)
        state = .connected(Self.capabilities.identity.model)
    }

    func stop() {
        state = .stopped
    }

    func requestHealthSync(requestID: UUID, after cursor: Int64, maximumSampleCount: UInt16) {
        onHealthSyncEvent?(
            .failed("模拟手表继续使用本地 Fake Watch 同步，不走 BLE GATT 传输。")
        )
    }

    private static let capabilities = WatchCapabilities(
        identity: WatchIdentity(
            model: "GalaxyCompanion Debug Watch",
            wearOSVersion: "Simulator",
            firmwareVersion: "0.1.0-debug"
        ),
        enabled: [.heartRate, .steps, .calories, .distance],
        healthDataMode: .developmentSynthetic
    )
}
