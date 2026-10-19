import AppKit
import SwiftUI

// 各窗口共用的小部件：系统设置风格的彩色图标块、状态小标签、卡片底、按钮样式。
// macOS 26 以上用系统的玻璃效果，更老的系统退回到普通的材质和按钮。

/// 圆角方块里放一个白色 SF Symbol，和系统设置左边栏的图标一样。
struct IconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 28

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(color)
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .bottom))
            )
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                    .strokeBorder(.white.opacity(0.18), lineWidth: 0.5)
            )
            .overlay(
                Image(systemName: symbol)
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .frame(width: size, height: size)
            .shadow(color: color.opacity(0.25), radius: size * 0.08, y: size * 0.04)
    }
}

/// 胶囊形的状态小标签，例如「已开启」。
struct StatusPill: View {
    let text: String
    let color: Color
    var symbol: String?

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.caption2.weight(.bold)) }
            Text(text).font(.caption.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

extension Color {
    /// 系统的绿、蓝、橙等，和系统设置图标用的颜色一致。
    static let tileBlue = Color(red: 0.04, green: 0.48, blue: 1.0)
    static let tileGreen = Color(red: 0.19, green: 0.78, blue: 0.35)
    static let tileOrange = Color(red: 1.0, green: 0.58, blue: 0.0)
    static let tileRed = Color(red: 1.0, green: 0.27, blue: 0.23)
    static let tilePurple = Color(red: 0.62, green: 0.36, blue: 0.95)
    static let tileGray = Color(red: 0.56, green: 0.56, blue: 0.6)
    static let tileIndigo = Color(red: 0.35, green: 0.34, blue: 0.84)
}

extension View {
    /// 卡片底：淡淡的底色加一圈细边。
    func cardBackground(cornerRadius: CGFloat = 14, highlighted: Color? = nil) -> some View {
        background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(highlighted?.opacity(0.45) ?? Color.primary.opacity(0.08), lineWidth: highlighted == nil ? 0.5 : 1)
                )
        )
    }

    /// 主按钮：珊瑚色胶囊。自己画，窗口不在前台时也保持品牌色（系统的主按钮这时会变灰）。
    func prominentButton() -> some View {
        buttonStyle(CoralButtonStyle())
    }

    /// 次要按钮：中性的浅色胶囊（系统的玻璃按钮会被窗口的珊瑚色染色，和主按钮抢眼）。
    func secondaryButton() -> some View {
        buttonStyle(NeutralButtonStyle())
    }

    /// 浮在别的窗口上的小窗用的玻璃底。
    @ViewBuilder
    func floatingGlass(cornerRadius: CGFloat) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }
}

struct CoralButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(large ? .body.weight(.semibold) : .callout.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, large ? 18 : (small ? 10 : 13))
            .padding(.vertical, large ? 8 : (small ? 3 : 5))
            .background(
                Capsule()
                    .fill(Brand.coral)
                    .overlay(Capsule().fill(LinearGradient(colors: [.white.opacity(0.18), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.5))
                    .shadow(color: Brand.coralBottom.opacity(isEnabled ? 0.35 : 0), radius: 6, y: 2)
            )
            .brightness(configuration.isPressed ? -0.08 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

struct NeutralButtonStyle: ButtonStyle {
    @Environment(\.controlSize) private var controlSize
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let large = controlSize == .large
        let small = controlSize == .small || controlSize == .mini
        configuration.label
            .font(large ? .body.weight(.medium) : .callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, large ? 18 : (small ? 10 : 13))
            .padding(.vertical, large ? 8 : (small ? 3 : 5))
            .background(
                Capsule()
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.14 : 0.07))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            )
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(Capsule())
    }
}

/// 引导、授权小窗的底：窗口底色上，左上角透出一点珊瑚色的光。
struct BrandBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Brand.coralTop.opacity(scheme == .dark ? 0.22 : 0.16), .clear],
                           center: UnitPoint(x: 0.12, y: -0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.tilePurple.opacity(scheme == .dark ? 0.12 : 0.07), .clear],
                           center: UnitPoint(x: 1.0, y: 1.05), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// App 图标（打包后从 App 里取，用 swift run 跑时没有就画一个空方块）。
struct AppIconImage: View {
    var size: CGFloat

    var body: some View {
        if let icon = NSImage(named: "VoxPalm") {
            Image(nsImage: icon).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous).fill(Brand.ink).frame(width: size, height: size)
        }
    }
}
