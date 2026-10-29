import SwiftUI

enum NightCurrent {
    static let ink = Color(hex: 0x081318)
    static let current = Color(hex: 0x10252C)
    static let fog = Color(hex: 0xEAF3F4)
    static let mint = Color(hex: 0x87E8C9)
    static let blue = Color(hex: 0x81B0FF)
    static let amber = Color(hex: 0xFFB76B)
    static let rose = Color(hex: 0xFF8490)
    static let muted = Color(hex: 0x9DB0B7)
}

struct NightCurrentBackground: View {
    var body: some View {
        LinearGradient(
            colors: [NightCurrent.ink, Color(hex: 0x0C1D23), NightCurrent.current],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct CurrentCard<Content: View>: View {
    let title: String
    let symbol: String
    let tint: Color
    @ViewBuilder let content: Content

    init(
        title: String,
        symbol: String,
        tint: Color = NightCurrent.blue,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .textCase(.uppercase)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
    }
}

struct CurrentStatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Label(title, systemImage: "circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(tint.opacity(0.13), in: Capsule())
    }
}

struct CurrentPrimaryButton: View {
    let title: String
    let symbol: String
    let tint: Color
    let isLoading: Bool
    let action: () -> Void

    init(
        _ title: String,
        symbol: String,
        tint: Color = NightCurrent.mint,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tint = tint
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isLoading {
                    ProgressView().tint(NightCurrent.ink)
                } else {
                    Image(systemName: symbol)
                }
                Text(title)
            }
            .font(.headline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
        }
        .buttonStyle(.plain)
        .foregroundStyle(NightCurrent.ink)
        .background(tint, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

struct ConnectionOrbit: View {
    let connection: WatchTransportState
    let pairing: WatchPairingStatus

    private var tint: Color {
        if pairing == .trustedForCurrentConnection { return NightCurrent.mint }
        switch connection {
        case .scanning, .connecting, .discoveringServices: return NightCurrent.blue
        case .failed, .bluetoothUnavailable: return NightCurrent.rose
        default: return NightCurrent.amber
        }
    }

    private var symbol: String {
        if pairing == .trustedForCurrentConnection { return "lock.fill" }
        switch connection {
        case .scanning: return "dot.radiowaves.left.and.right"
        case .connecting, .discoveringServices: return "wave.3.right"
        case .failed, .bluetoothUnavailable: return "exclamationmark.triangle.fill"
        default: return "applewatch"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.16), lineWidth: 16)
            Circle()
                .trim(from: 0.08, to: pairing == .trustedForCurrentConnection ? 0.92 : 0.52)
                .stroke(tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
                .padding(17)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(tint)
                .accessibilityHidden(true)
        }
        .frame(width: 102, height: 102)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("连接状态：\(connection.title)，\(pairing.title)")
    }
}

struct CurrentSectionHeader: View {
    let eyebrow: String
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.4)
                .foregroundStyle(NightCurrent.mint)
            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(NightCurrent.fog)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(NightCurrent.muted)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
