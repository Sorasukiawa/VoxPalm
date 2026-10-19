import AppKit

/// 菜单栏图标的状态（design/README.md「状态」一节）。
enum MenuBarIconState: Equatable {
    case idle
    /// 按下了，还没满长按时间：● 珊瑚色一跳一跳
    case armed
    /// 正在听：● 珊瑚色，竖条跟着音量跳
    case listening
    /// 转写中：两行字从左往右填满
    case transcribing
    /// 暂停监听：● 变空心
    case paused
    /// 要处理（缺权限、设备没连上）：整体变淡，右下角黄点
    case attention

    var isAnimated: Bool { self == .armed || self == .listening || self == .transcribing }
}

/// 照品牌图标的三段（● 按钮、竖条、两行字）画菜单栏图标，坐标是 36 × 36 的设计稿画布，缩到 18 点。
enum MenuBarIcon {
    static let coral = NSColor(red: 1.0, green: 0.478, blue: 0.302, alpha: 1)   // #FF7A4D
    static let warn = NSColor(red: 0.96, green: 0.65, blue: 0.14, alpha: 1)

    /// - Parameters:
    ///   - time: 动画用的秒数
    ///   - level: 录音音量 0…1
    static func image(_ state: MenuBarIconState, time: Double = 0, level: Float = 0) -> NSImage {
        // 待命和暂停只有黑白，用模板图让系统自己配深浅色；有颜色的状态用 labelColor，画的时候跟着菜单栏外观走。
        let template = state == .idle || state == .paused
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let k = rect.width / 36
            let ink: NSColor = template ? .black : .labelColor
            func r(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NSRect { NSRect(x: x * k, y: y * k, width: w * k, height: h * k) }
            func fill(_ path: NSBezierPath, _ color: NSColor, _ alpha: CGFloat = 1) {
                color.withAlphaComponent(alpha).setFill()
                path.fill()
            }
            func capsule(_ rect: NSRect) -> NSBezierPath {
                NSBezierPath(roundedRect: rect, xRadius: min(rect.width, rect.height) / 2, yRadius: min(rect.width, rect.height) / 2)
            }
            func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }

            let dim: CGFloat = state == .attention ? 0.42 : (state == .paused ? 0.4 : 1)
            // ● 按钮
            switch state {
            case .armed:
                let scale = 0.72 + 0.28 * (0.5 + 0.5 * cos(2 * .pi * time / 0.9))
                let d = 9.2 * scale
                fill(NSBezierPath(ovalIn: r(8 - d / 2, 18 - d / 2, d, d)), coral)
            case .listening:
                fill(NSBezierPath(ovalIn: r(3.4, 13.4, 9.2, 9.2)), coral)
            case .paused:
                let ring = NSBezierPath(ovalIn: r(4.4, 14.4, 7.2, 7.2))
                ring.lineWidth = 2 * k
                ink.setStroke()
                ring.stroke()
            default:
                fill(NSBezierPath(ovalIn: r(3.4, 13.4, 9.2, 9.2)), ink, dim)
            }
            // 竖条（声波）
            var barScale = 1.0
            var barAlpha: CGFloat = dim
            if state == .listening {
                barScale = 0.35 + 0.65 * Double(min(1, max(0, level)))
            } else if state == .transcribing {
                barScale = 0.4
                barAlpha = 0.45
            }
            let barH = 18 * barScale
            fill(capsule(r(15.5, 18 - barH / 2, 4, barH)), ink, barAlpha)
            // 两行字
            let lineAlpha: CGFloat = (state == .armed || state == .listening) ? 0.35 : dim
            if state == .transcribing {
                let p1 = ease((time.truncatingRemainder(dividingBy: 1.1)) / 1.1)
                let p2 = ease(((time + 1.1 - 0.18).truncatingRemainder(dividingBy: 1.1)) / 1.1)
                fill(capsule(r(23, 12, max(4, 10 * p1), 4)), ink)
                fill(capsule(r(23, 20, max(4, 7 * p2), 4)), ink)
            } else {
                fill(capsule(r(23, 12, 10, 4)), ink, lineAlpha)
                fill(capsule(r(23, 20, 7, 4)), ink, lineAlpha)
            }
            if state == .attention {
                fill(NSBezierPath(ovalIn: r(26.5, 22.5, 9, 9)), warn)
            }
            return true
        }
        image.isTemplate = template
        image.accessibilityDescription = "掌声"
        return image
    }
}
