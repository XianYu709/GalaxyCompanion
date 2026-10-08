import SwiftUI

struct ContentView: View {
    let appState: AppState

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "applewatch.radiowaves.left.and.right")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)

                Text("GalaxyCompanion")
                    .font(.largeTitle.bold())

                Text("Sprint 1 · BLE 连接验证")
                    .font(.headline)

                VStack(alignment: .leading, spacing: 8) {
                    Text(appState.connectionState.title)
                        .font(.title3.weight(.semibold))
                    Text(appState.connectionState.detail)
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))

                Button("开始搜索手表") {
                    appState.startDeviceDiscovery()
                }
                .buttonStyle(.borderedProminent)

                Button("停止搜索") {
                    appState.stopDeviceDiscovery()
                }
                .buttonStyle(.bordered)

                Spacer()
            }
            .padding()
            .navigationTitle("状态")
        }
    }
}

#Preview {
    ContentView(appState: AppState())
}
