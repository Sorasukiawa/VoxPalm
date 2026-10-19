// 生成宣传封面：横版 1280×640（GitHub 社交预览、官网、推特）和竖版 1242×1660（小红书）。
// 字体用思源黑体（SIL OFL 1.1），需要先在本机安装 Source Han Sans CN。
// 用法：swift brand/tools/make_covers.swift brand
import AppKit

let brand = URL(fileURLWithPath: CommandLine.arguments[1])
let icon = NSImage(contentsOf: brand.appendingPathComponent("icon/VoxPalm-icon.svg"))!

func hex(_ s: String) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let cream = hex("#FFF7F2"), coral = hex("#D85A30"), coralDeep = hex("#B8461F")
let ink = hex("#2A1B15"), inkSoft = hex("#6B5A52"), line = hex("#EBDDD4")

func font(_ weight: String, _ size: CGFloat) -> NSFont { NSFont(name: "SourceHanSansCN-\(weight)", size: size)! }
func text(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]) }
func title(_ size: CGFloat) -> NSAttributedString {
    let t = NSMutableAttributedString(attributedString: text("掌声 ", font("Heavy", size), ink))
    t.append(text("VoxPalm", font("Bold", size), ink)); return t
}

/// 画布原点在左上角，y 向下，和设计稿的习惯一致。
func canvas(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
    let ctx = NSGraphicsContext(cgContext: cg, flipped: true); ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    cream.setFill(); NSRect(x: 0, y: 0, width: w, height: h).fill()
    draw()
    NSGraphicsContext.restoreGraphicsState(); return rep
}

func drawIcon(_ r: NSRect) { icon.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil) }

func centered(_ s: NSAttributedString, cx: CGFloat, y: CGFloat) { s.draw(at: NSPoint(x: cx - s.size().width / 2, y: y)) }

/// 一排胶囊标签，返回总宽度；cx 不为空时整排居中
@discardableResult
func pills(_ items: [String], size: CGFloat, x: CGFloat? = nil, cx: CGFloat? = nil, y: CGFloat) -> CGFloat {
    let f = font("Medium", size), padX = size * 0.9, padY = size * 0.45, gap = size * 0.6
    let widths = items.map { text($0, f, coralDeep).size().width + padX * 2 }
    let total = widths.reduce(0, +) + gap * CGFloat(items.count - 1)
    var px = x ?? (cx! - total / 2)
    for (i, s) in items.enumerated() {
        let t = text(s, f, coralDeep), r = NSRect(x: px, y: y, width: widths[i], height: t.size().height + padY * 2)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: r.height / 2, yRadius: r.height / 2)
        p.lineWidth = max(1.5, size / 12); coral.setStroke(); p.stroke()
        t.draw(at: NSPoint(x: px + padX, y: y + padY)); px += widths[i] + gap
    }
    return total
}

/// 珊瑚色面板里的大号图形：握着的按钮发出声波（和图标同一个造型）
func hero(panel: NSRect, cx: CGFloat, cy: CGFloat, scale k: CGFloat) {
    let bg = NSBezierPath(roundedRect: panel, xRadius: 72 * k, yRadius: 72 * k)
    NSGradient(starting: hex("#E66B3F"), ending: hex("#C94F28"))!.draw(in: bg, angle: 90)
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: cx, yBy: cy); t.rotate(byDegrees: 12); t.concat()
    let w = 150 * k, h = 322 * k
    NSGradient(starting: hex("#FFFBF8"), ending: hex("#F6E5DA"))!.draw(in: NSBezierPath(roundedRect: NSRect(x: -w / 2, y: -h / 2, width: w, height: h), xRadius: w / 2, yRadius: w / 2), angle: 90)
    let bx: CGFloat = 0, by = -h / 2 + 95 * k
    coral.setFill(); NSBezierPath(ovalIn: NSRect(x: bx - 42 * k, y: by - 42 * k, width: 84 * k, height: 84 * k)).fill()
    hex("#F0997B").setFill(); NSBezierPath(ovalIn: NSRect(x: bx - 14 * k, y: h / 2 - 86 * k - 14 * k, width: 28 * k, height: 28 * k)).fill()
    for r in [140 * k, 212 * k] {
        let p = NSBezierPath(); p.lineWidth = 32 * k; p.lineCapStyle = .round
        for (i, deg) in stride(from: -40.0, through: 40.0, by: 2.0).enumerated() {
            let a = deg * .pi / 180, pt = NSPoint(x: bx + r * cos(a), y: by + r * sin(a))
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        cream.setStroke(); p.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
}

/// 白色小窗：示意说出来的话正在变成文字
func dictationCard(_ r: NSRect, scale k: CGFloat) {
    let p = NSBezierPath(roundedRect: r, xRadius: 20 * k, yRadius: 20 * k)
    NSColor.white.setFill(); p.fill(); p.lineWidth = 1.5 * k; line.setStroke(); p.stroke()
    for i in 0..<3 {
        hex("#E3D8D1").setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + (24 + CGFloat(i) * 18) * k, y: r.minY + 22 * k, width: 12 * k, height: 12 * k)).fill()
    }
    let label = text("正在听写", font("Medium", 17 * k), coral), lw = label.size().width
    coral.setFill(); NSBezierPath(ovalIn: NSRect(x: r.maxX - lw - 44 * k, y: r.minY + 22 * k, width: 12 * k, height: 12 * k)).fill()
    label.draw(at: NSPoint(x: r.maxX - lw - 24 * k, y: r.minY + 17 * k))
    let body = text("帮我把这个函数改成异步的", font("Medium", 28 * k), ink)
    body.draw(at: NSPoint(x: r.minX + 24 * k, y: r.minY + 58 * k))
    coral.setFill(); NSRect(x: r.minX + 24 * k + body.size().width + 6 * k, y: r.minY + 62 * k, width: 3.5 * k, height: 36 * k).fill()
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let dir = brand.appendingPathComponent("cover")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

let tagline = "按住说话，松手出字"
let sub = "把遥控器和无线麦，变成 Mac 的语音按钮"
let scenes = ["语音编程", "办公输入", "录音剪辑"]
let footer = "开源 · 免费可用 · macOS"

// 横版 1280×640
save(canvas(1280, 640) {
    drawIcon(NSRect(x: 74, y: 56, width: 140, height: 140))  // 图标四周有透明留白，往右挪让可见边缘和文字左对齐
    title(64).draw(at: NSPoint(x: 88, y: 206))
    text(tagline, font("Bold", 50), coral).draw(at: NSPoint(x: 88, y: 300))
    text(sub, font("Regular", 25), inkSoft).draw(at: NSPoint(x: 88, y: 382))
    pills(scenes, size: 20, x: 88, y: 448)
    text(footer, font("Regular", 19), inkSoft).draw(at: NSPoint(x: 88, y: 552))
    hero(panel: NSRect(x: 712, y: 64, width: 504, height: 512), cx: 900, cy: 290, scale: 1)
    dictationCard(NSRect(x: 640, y: 446, width: 470, height: 128), scale: 1)
}, "VoxPalm-cover-1280x640.png")

// 竖版 1242×1660
save(canvas(1242, 1660) {
    drawIcon(NSRect(x: 521, y: 80, width: 200, height: 200))
    centered(title(96), cx: 621, y: 292)
    centered(text(tagline, font("Bold", 76), coral), cx: 621, y: 432)
    centered(text(sub, font("Regular", 38), inkSoft), cx: 621, y: 556)
    hero(panel: NSRect(x: 96, y: 680, width: 1050, height: 640), cx: 530, cy: 980, scale: 1.3)
    dictationCard(NSRect(x: 486, y: 1170, width: 680, height: 180), scale: 1.42)
    pills(scenes, size: 32, cx: 621, y: 1414)
    centered(text(footer, font("Regular", 30), inkSoft), cx: 621, y: 1546)
}, "VoxPalm-cover-1242x1660.png")
print("ok")
