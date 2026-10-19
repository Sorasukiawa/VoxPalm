// 把图标 SVG 导出成各尺寸 PNG、iconset、菜单栏 PNG 和预览图；导出后再运行：
// iconutil -c icns brand/icon/VoxPalm.iconset -o brand/icon/VoxPalm.icns
// 用法：swift brand/tools/export_icons.swift brand
import AppKit
let brand = URL(fileURLWithPath: CommandLine.arguments[1])
func load(_ p: String) -> NSImage { guard let i = NSImage(contentsOf: brand.appendingPathComponent(p)) else { fatalError("读不了 \(p)") }; return i }
func bitmap(_ w: Int, _ h: Int, _ draw: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: w, height: h)
    NSGraphicsContext.saveGraphicsState(); let ctx = NSGraphicsContext(bitmapImageRep: rep)!; ctx.imageInterpolation = .high; NSGraphicsContext.current = ctx
    draw(); NSGraphicsContext.restoreGraphicsState(); return rep
}
func save(_ rep: NSBitmapImageRep, _ p: String) { let u = brand.appendingPathComponent(p); try! FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true); try! rep.representation(using: .png, properties: [:])!.write(to: u) }
func render(_ img: NSImage, _ px: Int) -> NSBitmapImageRep { bitmap(px, px) { img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)) } }

let full = load("icon/VoxPalm-icon.svg"), small = load("icon/VoxPalm-icon-small.svg"), menu = load("menubar/MenuBarIconTemplate.svg")
let iconset: [(String, NSImage, Int)] = [
    ("icon_16x16", small, 16), ("icon_16x16@2x", small, 32), ("icon_32x32", small, 32), ("icon_32x32@2x", full, 64),
    ("icon_128x128", full, 128), ("icon_128x128@2x", full, 256), ("icon_256x256", full, 256), ("icon_256x256@2x", full, 512),
    ("icon_512x512", full, 512), ("icon_512x512@2x", full, 1024)]
var reps: [Int: NSBitmapImageRep] = [:]
for (name, img, px) in iconset { let r = render(img, px); save(r, "icon/VoxPalm.iconset/\(name).png"); if name.hasSuffix("x\(px)") || px == 1024 || px == 64 { reps[px] = r } }
reps[16] = render(small, 16); reps[32] = render(small, 32)
save(reps[1024]!, "icon/VoxPalm-icon-1024.png")
save(render(menu, 18), "menubar/MenuBarIconTemplate.png"); save(render(menu, 36), "menubar/MenuBarIconTemplate@2x.png")

// 预览图：左浅右深，各放大图标、实际尺寸阶梯、16/32 放大 4 倍看清晰度、菜单栏样子
func tinted(_ img: NSImage, _ c: NSColor, _ px: Int) -> NSImage {
    let r = bitmap(px, px) { img.draw(in: NSRect(x: 0, y: 0, width: px, height: px)); c.set(); NSRect(x: 0, y: 0, width: px, height: px).fill(using: .sourceAtop) }
    let i = NSImage(size: NSSize(width: px, height: px)); i.addRepresentation(r); return i
}
func nsimg(_ r: NSBitmapImageRep) -> NSImage { let i = NSImage(size: r.size); i.addRepresentation(r); return i }
let W = 1600, H = 900
let sheet = bitmap(W, H) {
    for (i, dark) in [false, true].enumerated() {
        let x0 = CGFloat(i * W / 2), bg = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.96, alpha: 1), fg = dark ? NSColor.white : NSColor.black
        bg.setFill(); NSRect(x: x0, y: 0, width: CGFloat(W / 2), height: CGFloat(H)).fill()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 20, weight: .medium), .foregroundColor: fg.withAlphaComponent(0.7)]
        (dark ? "深色背景" : "浅色背景").draw(at: NSPoint(x: x0 + 40, y: CGFloat(H) - 56), withAttributes: attrs)
        full.draw(in: NSRect(x: x0 + 40, y: CGFloat(H) - 360, width: 280, height: 280))
        var x = x0 + 360
        for px in [128, 64, 32, 16] { let r = reps[px]!; nsimg(r).draw(in: NSRect(x: x, y: CGFloat(H) - 80 - CGFloat(px) - 100, width: CGFloat(px), height: CGFloat(px))); x += CGFloat(px) + 28 }
        "实际像素：128 / 64 / 32 / 16".draw(at: NSPoint(x: x0 + 360, y: CGFloat(H) - 120), withAttributes: attrs)
        NSGraphicsContext.current!.imageInterpolation = .none
        nsimg(reps[32]!).draw(in: NSRect(x: x0 + 40, y: 180, width: 128, height: 128)); nsimg(reps[16]!).draw(in: NSRect(x: x0 + 200, y: 180, width: 128, height: 128))
        NSGraphicsContext.current!.imageInterpolation = .high
        "32 和 16 放大 4 倍".draw(at: NSPoint(x: x0 + 40, y: 320), withAttributes: attrs)
        let bar = NSRect(x: x0 + 380, y: 210, width: 360, height: 48)
        (dark ? NSColor(white: 0.2, alpha: 1) : NSColor(white: 0.88, alpha: 1)).setFill(); NSBezierPath(roundedRect: bar, xRadius: 10, yRadius: 10).fill()
        tinted(menu, fg, 36).draw(in: NSRect(x: bar.minX + 24, y: bar.minY + 6, width: 36, height: 36))
        tinted(menu, fg, 18).draw(in: NSRect(x: bar.minX + 90, y: bar.minY + 15, width: 18, height: 18))
        "菜单栏：@2x / 实际 18px".draw(at: NSPoint(x: x0 + 380, y: 270), withAttributes: attrs)
    }
}
save(sheet, "preview.png"); print("ok")
