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

/// 引导、设置窗口、授权小窗的底：窗口底色上，左上角透出一点珊瑚色的光。
struct BrandBackdrop: View {
    /// 面板这种自带材质的地方不垫窗口底色，只叠光
    var opaque = true
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            if opaque { Color(nsColor: .windowBackgroundColor) }
            RadialGradient(colors: [Brand.coralTop.opacity(scheme == .dark ? 0.22 : 0.16), .clear],
                           center: UnitPoint(x: 0.12, y: -0.05), startRadius: 0, endRadius: 420)
            RadialGradient(colors: [Color.tilePurple.opacity(scheme == .dark ? 0.12 : 0.07), .clear],
                           center: UnitPoint(x: 1.0, y: 1.05), startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

// MARK: - 设置页共用的版式（和引导同一套：大标题加一句说明、圆角卡片、彩色图标块）

/// 设置里的一块卡片：左上彩色图标块、标题和一句说明，右边可以放按钮；下面是内容。
struct SettingsCard<Accessory: View, Content: View>: View {
    let title: String
    var subtitle: String?
    var symbol: String?
    var color: Color = .tileGray
    var highlighted: Color?
    @ViewBuilder var accessory: () -> Accessory
    @ViewBuilder var content: () -> Content

    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, color: Color = .tileGray, highlighted: Color? = nil,
         @ViewBuilder accessory: @escaping () -> Accessory, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.color = color
        self.highlighted = highlighted
        self.accessory = accessory
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 12) {
                if let symbol { IconTile(symbol: symbol, color: color, size: 30) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                accessory()
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground(cornerRadius: 16, highlighted: highlighted)
    }
}

extension SettingsCard where Accessory == EmptyView {
    init(_ title: String, subtitle: String? = nil, symbol: String? = nil, color: Color = .tileGray, highlighted: Color? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title, subtitle: subtitle, symbol: symbol, color: color, highlighted: highlighted, accessory: { EmptyView() }, content: content)
    }
}

/// 卡片里的一行设置：左边名字（可带一句小字），右边控件。
struct SettingRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: () -> Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            control()
        }
        .frame(minHeight: 32)
        .padding(.vertical, 5)
    }
}

/// 卡片里两行之间的细线
struct RowDivider: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5)
    }
}

/// 灰色小字说明，前面带一个小图标（代替系统表单分组下面的脚注）。
struct Hint: View {
    let text: String
    var symbol = "info.circle"

    init(_ text: String, symbol: String = "info.circle") {
        self.text = text
        self.symbol = symbol
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: symbol).font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 不画刻度的滑块：自己把值吸到步长上（系统滑块给了 step 会画一排很密的刻度）。
struct SnapSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double

    init(value: Binding<Double>, in range: ClosedRange<Double>, step: Double) {
        _value = value
        self.range = range
        self.step = step
    }

    var body: some View {
        Slider(value: Binding(get: { value }, set: { raw in
            let stepped = range.lowerBound + ((raw - range.lowerBound) / step).rounded() * step
            let snapped = min(range.upperBound, (stepped * 10000).rounded() / 10000)
            if abs(snapped - value) > step / 1000 { value = snapped }
        }), in: range)
    }
}

/// 滑块旁边的数值：等宽数字的小胶囊。
struct ValueChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.monospacedDigit().weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .contentTransition(.numericText())
    }
}

extension Color {
    /// 分段控件选中那一段的底：浅色白、深色灰（设计稿 .ed-tabs .thumb）
    static let tabThumb = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.333, green: 0.322, blue: 0.361, alpha: 1)
            : NSColor.white
    })
}

/// 分段切换（控制设备 | 收音设备、图 | 表）：选中的底色用弹簧滑过去，和编辑小窗的手势分段一个样子。
struct PillTabs<Value: Hashable>: View {
    struct Option {
        let value: Value
        let title: String
        var symbol: String?
    }

    @Binding var selection: Value
    let options: [Option]
    var segmentWidth: CGFloat?
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let on = option.value == selection
                Button {
                    withAnimation(Motion.pick(Motion.bounce)) { selection = option.value }
                } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                        Text(option.title)
                    }
                    .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .primary : .secondary)
                    .padding(.horizontal, 12)
                    .frame(width: segmentWidth, height: 24)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.tabThumb)
                                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// 只有图标的圆形小按钮（刷新、关闭这类）。
struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.primary.opacity(hovering ? 0.1 : 0.06)))
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(TileButtonStyle())
        .onHover { hovering = $0 }
        .help(help)
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
