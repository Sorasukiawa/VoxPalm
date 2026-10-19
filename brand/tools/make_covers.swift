// 生成宣传封面：横版 1280×640（GitHub 社交预览、官网、推特）和竖版 1242×1660（小红书）。
// 画面只出现一次 Logo（左上角的横排组合），主视觉讲用法：按住按钮 → 说话 → 文字出现。
// 字体用思源黑体（SIL OFL 1.1），需要先在本机安装 Source Han Sans CN；需要先运行 make_wordmark.swift。
// 用法：swift brand/tools/make_covers.swift brand
import AppKit

let brand = URL(fileURLWithPath: CommandLine.arguments[1])
let lockup = NSImage(contentsOf: brand.appendingPathComponent("wordmark/VoxPalm-lockup-light.svg"))!

func hex(_ s: String) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let cream = hex("#FFF7F2"), coral = hex("#D85A30"), coralDeep = hex("#B8461F"), coralSoft = hex("#FBE3D8")
let ink = hex("#1F1D2B"), inkSoft = hex("#5E5A6E"), line = hex("#EBDDD4")

func font(_ weight: String, _ size: CGFloat) -> NSFont { NSFont(name: "SourceHanSansCN-\(weight)", size: size)! }
func text(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]) }

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

/// 左上角的横排 Logo；图标四周有透明留白，往左挪一点让可见边缘对齐 x
func drawLockup(x: CGFloat, y: CGFloat, height h: CGFloat) {
    let w = lockup.size.width * h / lockup.size.height, inset = h * 25 / 256
    lockup.draw(in: NSRect(x: x - inset, y: y, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

/// 一排胶囊标签
func pills(_ items: [String], size: CGFloat, x: CGFloat, y: CGFloat) {
    let f = font("Medium", size), padX = size * 0.9, padY = size * 0.45, gap = size * 0.6
    var px = x
    for s in items {
        let t = text(s, f, coralDeep), r = NSRect(x: px, y: y, width: t.size().width + padX * 2, height: t.size().height + padY * 2)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: r.height / 2, yRadius: r.height / 2)
        p.lineWidth = max(1.5, size / 12); coral.setStroke(); p.stroke()
        t.draw(at: NSPoint(x: px + padX, y: y + padY)); px += r.width + gap
    }
}

/// 从正上方看的实体按钮：浅色光圈 + 带厚度的珊瑚色按键 + 「按住」
func pushButton(cx: CGFloat, cy: CGFloat, r: CGFloat) {
    coralSoft.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - r * 1.45, y: cy - r * 1.45, width: r * 2.9, height: r * 2.9)).fill()
    coralDeep.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r + r * 0.09, width: r * 2, height: r * 2)).fill()
    NSGradient(starting: hex("#E66B3F"), ending: hex("#D85A30"))!.draw(in: NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r - r * 0.03, width: r * 2, height: r * 2)), angle: 90)
    let label = text("按住", font("Bold", r * 0.42), cream)
    label.draw(at: NSPoint(x: cx - label.size().width / 2, y: cy - label.size().height / 2 - r * 0.05))
}

/// 声波条：中间高、两头低
func waveform(x0: CGFloat, x1: CGFloat, cy: CGFloat, maxH: CGFloat, barW: CGFloat) {
    let n = Int((x1 - x0 + barW) / (barW * 2))
    for i in 0..<n {
        let t = CGFloat(i) / CGFloat(max(n - 1, 1))
        let envelope = 0.35 + 0.65 * sin(t * .pi)
        let h = max(barW, maxH * envelope * (0.45 + 0.55 * abs(sin(CGFloat(i) * 1.7 + 0.6))))
        let r = NSRect(x: x0 + CGFloat(i) * barW * 2, y: cy - h / 2, width: barW, height: h)
        coral.setFill(); NSBezierPath(roundedRect: r, xRadius: barW / 2, yRadius: barW / 2).fill()
    }
}

/// 白色小窗：说出来的话变成文字
func dictationCard(_ r: NSRect, scale k: CGFloat) {
    let p = NSBezierPath(roundedRect: r, xRadius: 22 * k, yRadius: 22 * k)
    NSColor.white.setFill(); p.fill(); p.lineWidth = 1.5 * k; line.setStroke(); p.stroke()
    for i in 0..<3 {
        hex("#E3D8D1").setFill()
        NSBezierPath(ovalIn: NSRect(x: r.minX + (26 + CGFloat(i) * 18) * k, y: r.minY + 24 * k, width: 12 * k, height: 12 * k)).fill()
    }
    let label = text("正在听写", font("Medium", 17 * k), coral), lw = label.size().width
    coral.setFill(); NSBezierPath(ovalIn: NSRect(x: r.maxX - lw - 46 * k, y: r.minY + 24 * k, width: 12 * k, height: 12 * k)).fill()
    label.draw(at: NSPoint(x: r.maxX - lw - 26 * k, y: r.minY + 19 * k))
    let body = text("帮我把这个函数改成异步的", font("Medium", 30 * k), ink)
    body.draw(at: NSPoint(x: r.minX + 26 * k, y: r.minY + 62 * k))
    coral.setFill(); NSRect(x: r.minX + 26 * k + body.size().width + 6 * k, y: r.minY + 67 * k, width: 3.5 * k, height: 38 * k).fill()
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let dir = brand.appendingPathComponent("cover")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

let sub = "把遥控器和无线麦，变成 Mac 的语音按钮"
let scenes = ["语音编程", "办公输入", "录音剪辑"]
let footer = "开源 · 免费可用 · macOS"

// 横版 1280×640：左边标语，右边「按钮 → 声波 → 文字」
save(canvas(1280, 640) {
    drawLockup(x: 88, y: 56, height: 64)
    text("按住说话，", font("Heavy", 88), ink).draw(at: NSPoint(x: 85, y: 160))
    text("松手出字。", font("Heavy", 88), coral).draw(at: NSPoint(x: 85, y: 272))
    text(sub, font("Regular", 26), inkSoft).draw(at: NSPoint(x: 88, y: 410))
    pills(scenes, size: 19, x: 88, y: 476)
    text(footer, font("Regular", 18), inkSoft).draw(at: NSPoint(x: 88, y: 566))
    pushButton(cx: 800, cy: 228, r: 74)
    waveform(x0: 930, x1: 1192, cy: 228, maxH: 150, barW: 11)
    dictationCard(NSRect(x: 688, y: 392, width: 504, height: 136), scale: 1)
}, "VoxPalm-cover-1280x640.png")

// 竖版 1242×1660：上面标语，下面「按钮 → 声波 → 文字」
save(canvas(1242, 1660) {
    drawLockup(x: 96, y: 96, height: 92)
    text("按住说话，", font("Heavy", 150), ink).draw(at: NSPoint(x: 92, y: 250))
    text("松手出字。", font("Heavy", 150), coral).draw(at: NSPoint(x: 92, y: 436))
    text(sub, font("Regular", 40), inkSoft).draw(at: NSPoint(x: 96, y: 668))
    pushButton(cx: 300, cy: 950, r: 112)
    waveform(x0: 500, x1: 1146, cy: 950, maxH: 230, barW: 17)
    dictationCard(NSRect(x: 96, y: 1150, width: 1050, height: 182), scale: 1.5)
    pills(scenes, size: 32, x: 96, y: 1450)
    text(footer, font("Regular", 30), inkSoft).draw(at: NSPoint(x: 96, y: 1566))
}, "VoxPalm-cover-1242x1660.png")
print("ok")
