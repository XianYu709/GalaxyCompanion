import SwiftUI

struct ContentView: View {
    let appState: AppState
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.025, green: 0.05, blue: 0.09), Color(red: 0.04, green: 0.13, blue: 0.19)], startPoint: .topLeading, endPoint: .bottomTrailing).ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    connectionPanel
                    if let c = appState.capabilities { Panel(title: "设备能力", icon: "cpu") { Text(c.identity.model).font(.headline); Text(c.enabled.sorted { $0.rawValue < $1.rawValue }.map(\.displayName).joined(separator: " · ")).foregroundStyle(.white.opacity(0.62)); Text(c.healthDataMode.displayName).font(.caption).foregroundStyle(.orange) } }
                    Panel(title: "Apple Health", icon: "heart.text.square") { Text(appState.healthKitAuthorizationStatus.title).font(.headline); Text(appState.healthKitAuthorizationStatus.detail).font(.footnote).foregroundStyle(.white.opacity(0.62)); if appState.healthKitAuthorizationStatus.canRequestAuthorization { Button("授权写入") { appState.requestHealthKitAuthorization() }.buttonStyle(.bordered).tint(.cyan) } }
                    Panel(title: "健康同步", icon: "arrow.triangle.2.circlepath") { Text(appState.healthSyncStatus.title).font(.headline); Text(appState.healthSyncStatus.detail).font(.footnote).foregroundStyle(.white.opacity(0.62)); Label("不展示模拟样本", systemImage: "checkmark.shield").font(.caption.weight(.medium)).foregroundStyle(.cyan) }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 108)
            }
            .safeAreaInset(edge: .bottom) { Button { appState.startDeviceDiscovery() } label: { Label("搜索我的手表", systemImage: "magnifyingglass").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 15) }.buttonStyle(.plain).foregroundStyle(Color(red: 0.02, green: 0.09, blue: 0.12)).background(.cyan, in: RoundedRectangle(cornerRadius: 18)).padding(.horizontal, 20).padding(.vertical, 10).background(.ultraThinMaterial) }
        }.preferredColorScheme(.dark)
    }
    private var header: some View { VStack(alignment: .leading, spacing: 8) { HStack { Image(systemName: "wave.3.right.circle.fill").font(.system(size: 32)).foregroundStyle(.cyan); Spacer(); Text("连接实验室").font(.caption.weight(.bold)).padding(.horizontal, 10).padding(.vertical, 6).background(.cyan.opacity(0.16), in: Capsule()) }; Text("Galaxy\nCompanion").font(.system(size: 34, weight: .bold, design: .rounded)).tracking(-1); Text("手表健康数据的安全中转站").foregroundStyle(.white.opacity(0.6)) } }
    private var connectionPanel: some View { Panel(title: "连接状态", icon: "dot.radiowaves.left.and.right") { Text(appState.connectionState.title).font(.title3.weight(.semibold)); Text(appState.connectionState.detail).font(.footnote).foregroundStyle(.white.opacity(0.62)); Divider().overlay(.white.opacity(0.12)); Label(appState.transportMode.title, systemImage: "applewatch").font(.footnote.weight(.medium)).foregroundStyle(.cyan) } }
}

private struct Panel<Content: View>: View { let title: String; let icon: String; @ViewBuilder let content: Content; var body: some View { VStack(alignment: .leading, spacing: 11) { Label(title, systemImage: icon).font(.caption.weight(.bold)).foregroundStyle(.cyan); content }.padding(18).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 22)).overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.1))) } }
private extension WatchCapability { var displayName: String { switch self { case .heartRate: "心率"; case .steps: "步数"; case .calories: "卡路里"; case .distance: "距离"; default: rawValue } } }
private extension HealthDataMode { var displayName: String { switch self { case .unavailable: "健康数据：未提供（认证配对尚未实现）"; case .developmentSynthetic: "健康数据：仅开发用合成样本"; case .authenticatedMeasurement: "健康数据：已声明为认证测量来源" } } }
#Preview { ContentView(appState: AppState()) }
