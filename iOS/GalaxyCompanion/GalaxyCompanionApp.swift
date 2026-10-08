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
    private(set) var connectionState: WatchTransportState

    init(transport: any WatchTransport = CoreBluetoothWatchTransport()) {
        self.transport = transport
        self.connectionState = transport.state
        transport.onStateChange = { [weak self] state in
            self?.connectionState = state
        }
    }

    func startDeviceDiscovery() {
        transport.startDiscovery()
    }

    func stopDeviceDiscovery() {
        transport.stop()
    }
}
