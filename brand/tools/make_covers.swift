// 生成宣传封面：横版 1280×640（GitHub 社交预览、官网、推特）和竖版 1242×1660（小红书）。
// 和图标同一套墨色底；Logo 只在左上角出现一次。主视觉不再重复图标里的「按钮 → 声波 → 文字」，
// 而是画真实场景：手里的遥控器和别在身上的无线麦，对着 Mac 上的 AI 编程窗口说话出字。
// 字体用思源黑体（SIL OFL 1.1），需要先在本机安装 Source Han Sans CN；需要先运行 make_wordmark.swift。
// 用法：swift brand/tools/make_covers.swift brand
import AppKit

let brand = URL(fileURLWithPath: CommandLine.arguments[1])
let lockup = NSImage(contentsOf: brand.appendingPathComponent("wordmark/VoxPalm-lockup-dark.svg"))!

func hex(_ s: String, _ a: CGFloat = 1) -> NSColor {
    let v = Int(s.dropFirst(), radix: 16)!
    return NSColor(srgbRed: CGFloat(v >> 16 & 0xFF) / 255, green: CGFloat(v >> 8 & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: a)
}
let bgTop = hex("#24213A"), bgBottom = hex("#14121C")
let cream = hex("#FFF3EA"), coral = hex("#FF7A4D"), coralText = hex("#FF9A75")
let soft = hex("#ADA7C2"), muted = hex("#7C7694")
let panel = hex("#2A2640"), panelLine = hex("#3C3857"), dim = hex("#4A4566")

func font(_ weight: String, _ size: CGFloat) -> NSFont { NSFont(name: "SourceHanSansCN-\(weight)", size: size)! }
func text(_ s: String, _ f: NSFont, _ c: NSColor) -> NSAttributedString { NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: c]) }
func pill(_ r: NSRect, _ c: NSColor) { c.setFill(); NSBezierPath(roundedRect: r, xRadius: min(r.width, r.height) / 2, yRadius: min(r.width, r.height) / 2).fill() }
func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) { c.setFill(); NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2)).fill() }

/// 画布原点在左上角，y 向下，和设计稿的习惯一致。
func canvas(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: CGFloat(h)); cg.scaleBy(x: 1, y: -1)
    let ctx = NSGraphicsContext(cgContext: cg, flipped: true); ctx.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: 90)
    draw()
    NSGraphicsContext.restoreGraphicsState(); return rep
}

/// 左上角的横排 Logo；图标四周有透明留白，往左挪一点让可见边缘对齐 x
func drawLockup(x: CGFloat, y: CGFloat, height h: CGFloat) {
    let w = lockup.size.width * h / lockup.size.height, inset = h * 25 / 256
    lockup.draw(in: NSRect(x: x - inset, y: y, width: w, height: h), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
}

/// 一排描边胶囊标签
func pills(_ items: [String], size: CGFloat, x: CGFloat, y: CGFloat) {
    let f = font("Medium", size), padX = size * 0.9, padY = size * 0.45, gap = size * 0.6
    var px = x
    for s in items {
        let t = text(s, f, coralText), r = NSRect(x: px, y: y, width: t.size().width + padX * 2, height: t.size().height + padY * 2)
        let p = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: r.height / 2, yRadius: r.height / 2)
        p.lineWidth = max(1.5, size / 12); coral.withAlphaComponent(0.8).setStroke(); p.stroke()
        t.draw(at: NSPoint(x: px + padX, y: y + padY)); px += r.width + gap
    }
}

/// Mac 上的 AI 编程窗口：前几行是已经写好的内容，最后一行是正在听写出来的话
func window(_ r: NSRect, k: CGFloat) {
    let p = NSBezierPath(roundedRect: r, xRadius: 22 * k, yRadius: 22 * k)
    panel.setFill(); p.fill(); p.lineWidth = 1.5 * k; panelLine.setStroke(); p.stroke()
    for i in 0..<3 { circle(r.minX + (26 + CGFloat(i) * 20) * k, r.minY + 26 * k, 6 * k, dim) }
    let label = text("正在听写", font("Medium", 17 * k), coralText), lw = label.size().width
    circle(r.maxX - lw - 40 * k, r.minY + 27 * k, 6 * k, coral)
    label.draw(at: NSPoint(x: r.maxX - lw - 26 * k, y: r.minY + 15 * k))
    let x0 = r.minX + 28 * k
    for (i, w) in [300.0, 380.0, 220.0].enumerated() { pill(NSRect(x: x0, y: r.minY + (66 + CGFloat(i) * 30) * k, width: CGFloat(w) * k, height: 14 * k), panelLine) }
    let prompt = text("›", font("Bold", 32 * k), coral), body = text("帮我把这个函数改成异步的", font("Medium", 30 * k), cream)
    let ty = r.minY + 168 * k
    prompt.draw(at: NSPoint(x: x0, y: ty - 3 * k))
    body.draw(at: NSPoint(x: x0 + 30 * k, y: ty))
    pill(NSRect(x: x0 + 30 * k + body.size().width + 6 * k, y: ty + 5 * k, width: 3.5 * k, height: 36 * k), coral)
}

func rotated(_ cx: CGFloat, _ cy: CGFloat, _ deg: CGFloat, _ draw: () -> Void) {
    NSGraphicsContext.saveGraphicsState()
    let t = NSAffineTransform(); t.translateX(by: cx, yBy: cy); t.rotate(byDegrees: deg); t.concat()
    draw(); NSGraphicsContext.restoreGraphicsState()
}

/// 手持遥控器：顶上的珊瑚色按键正在被按住，外面两圈提示「按下」
func remote(_ cx: CGFloat, _ cy: CGFloat, k: CGFloat, deg: CGFloat) {
    rotated(cx, cy, deg) {
        pill(NSRect(x: -42 * k, y: -135 * k, width: 84 * k, height: 270 * k), cream)
        for (r, a) in [(48.0, 0.18), (36.0, 0.4)] {
            let ring = NSBezierPath(ovalIn: NSRect(x: -CGFloat(r) * k, y: (-80 - CGFloat(r)) * k, width: CGFloat(r) * 2 * k, height: CGFloat(r) * 2 * k))
            ring.lineWidth = 3 * k; coral.withAlphaComponent(CGFloat(a)).setStroke(); ring.stroke()
        }
        circle(0, -80 * k, 24 * k, coral)
        let grey = hex("#D9D3E6")
        circle(-16 * k, -22 * k, 8 * k, grey); circle(16 * k, -22 * k, 8 * k, grey); circle(0, 6 * k, 8 * k, grey)
        pill(NSRect(x: -16 * k, y: 40 * k, width: 32 * k, height: 10 * k), grey)
        pill(NSRect(x: -16 * k, y: 62 * k, width: 32 * k, height: 10 * k), grey)
    }
}

/// 别在衣服上的无线麦发射器：夹子 + 网罩 + 指示灯
func lapelMic(_ cx: CGFloat, _ cy: CGFloat, k: CGFloat, deg: CGFloat) {
    rotated(cx, cy, deg) {
        pill(NSRect(x: -30 * k, y: -84 * k, width: 60 * k, height: 20 * k), hex("#CFC8DE"))
        hex("#E9E4F2").setFill(); NSBezierPath(roundedRect: NSRect(x: -59 * k, y: -70 * k, width: 118 * k, height: 140 * k), xRadius: 30 * k, yRadius: 30 * k).fill()
        for row in 0..<4 { for col in 0..<5 { circle((-32 + CGFloat(col) * 16) * k, (-42 + CGFloat(row) * 15) * k, 4.2 * k, hex("#B0A9C4")) } }
        circle(-30 * k, 40 * k, 9 * k, coral)
    }
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    let dir = brand.appendingPathComponent("cover")
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try! rep.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
}

let sub = "把遥控器和无线麦，变成 Mac 的语音按钮"
let scenes = ["语音编程", "办公输入", "录音剪辑"]
let footer = "开源 · 免费可用 · macOS"

// 横版 1280×640
save(canvas(1280, 640) {
    drawLockup(x: 88, y: 56, height: 60)
    text("按住说话，", font("Heavy", 84), cream).draw(at: NSPoint(x: 85, y: 156))
    text("松手出字。", font("Heavy", 84), coral).draw(at: NSPoint(x: 85, y: 262))
    text(sub, font("Regular", 25), soft).draw(at: NSPoint(x: 88, y: 392))
    pills(scenes, size: 19, x: 88, y: 458)
    text(footer, font("Regular", 18), muted).draw(at: NSPoint(x: 88, y: 566))
    window(NSRect(x: 652, y: 120, width: 548, height: 236), k: 1)
    remote(676, 456, k: 0.92, deg: -14)
    lapelMic(884, 478, k: 0.95, deg: 9)
}, "VoxPalm-cover-1280x640.png")

// 竖版 1242×1660
save(canvas(1242, 1660) {
    drawLockup(x: 96, y: 96, height: 84)
    text("按住说话，", font("Heavy", 150), cream).draw(at: NSPoint(x: 92, y: 240))
    text("松手出字。", font("Heavy", 150), coral).draw(at: NSPoint(x: 92, y: 424))
    text(sub, font("Regular", 40), soft).draw(at: NSPoint(x: 96, y: 652))
    window(NSRect(x: 96, y: 780, width: 1050, height: 400), k: 1.62)
    remote(900, 1292, k: 1.35, deg: -14)
    lapelMic(1078, 1318, k: 1.3, deg: 9)
    pills(scenes, size: 32, x: 96, y: 1468)
    text(footer, font("Regular", 30), muted).draw(at: NSPoint(x: 96, y: 1574))
}, "VoxPalm-cover-1242x1660.png")
print("ok")
