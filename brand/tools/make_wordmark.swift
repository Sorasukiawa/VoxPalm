// 生成文字标志：图标 + 「掌声 VoxPalm」横排组合，以及纯文字版。
// 文字转成路径写进 SVG，别的电脑没装思源黑体也能正常显示。
// 用法：swift brand/tools/make_wordmark.swift brand
import AppKit
import CoreText

let brand = URL(fileURLWithPath: CommandLine.arguments[1])

struct TextShape { let d: String; let width: CGFloat }

/// 把一段文字转成 SVG 路径，原点在 (x, baseline)，SVG 坐标 y 向下。
func textShape(_ s: String, _ fontName: String, _ size: CGFloat, x: CGFloat, baseline: CGFloat) -> TextShape {
    guard let font = NSFont(name: fontName, size: size) else { fatalError("缺字体 \(fontName)") }
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: [.font: font]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let runFont = (CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n), pos = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &pos)
        for i in 0..<n {
            guard let g = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) else { continue }
            path.addPath(g, transform: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x + pos[i].x, ty: baseline - pos[i].y))
        }
    }
    var d = ""
    func f(_ v: CGFloat) -> String { String(format: "%.1f", v) }
    path.applyWithBlock { el in
        let p = el.pointee.points
        switch el.pointee.type {
        case .moveToPoint: d += "M\(f(p[0].x)) \(f(p[0].y))"
        case .addLineToPoint: d += "L\(f(p[0].x)) \(f(p[0].y))"
        case .addQuadCurveToPoint: d += "Q\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y))"
        case .addCurveToPoint: d += "C\(f(p[0].x)) \(f(p[0].y)) \(f(p[1].x)) \(f(p[1].y)) \(f(p[2].x)) \(f(p[2].y))"
        case .closeSubpath: d += "Z"
        @unknown default: break
        }
    }
    return TextShape(d: d, width: CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
}

/// 取出图标 SVG 里 <svg> 内部的内容，用来嵌进组合标志。
func iconInner() -> String {
    let s = try! String(contentsOf: brand.appendingPathComponent("icon/VoxPalm-icon.svg"), encoding: .utf8)
    let start = s.range(of: "</title>")!.upperBound, end = s.range(of: "</svg>", options: .backwards)!.lowerBound
    return String(s[start..<end])
}

let size: CGFloat = 120, height: CGFloat = 256
// 思源黑体的汉字字面框大约在基线上方 0.88em、下方 0.12em，让字面框和图标垂直居中
let baseline = height / 2 + size * 0.38
let gap: CGFloat = 34

func lockup(textColor: String, withIcon: Bool) -> String {
    let x0: CGFloat = withIcon ? 231 + 30 : 0
    let zh = textShape("掌声", "SourceHanSansCN-Heavy", size, x: x0, baseline: baseline)
    let en = textShape("VoxPalm", "SourceHanSansCN-Bold", size, x: x0 + zh.width + gap, baseline: baseline)
    let w = Int((x0 + zh.width + gap + en.width + (withIcon ? 25 : 0)).rounded(.up))
    // 图标源文件是 1024 画布，缩到 256 高
    let icon = withIcon ? "\n  <g transform=\"scale(0.25)\">\(iconInner())</g>" : ""
    return """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(w)" height="\(Int(height))" viewBox="0 0 \(w) \(Int(height))">
      <title>掌声 VoxPalm</title>\(icon)
      <path d="\(zh.d)" fill="\(textColor)"/>
      <path d="\(en.d)" fill="\(textColor)"/>
    </svg>

    """
}

let dir = brand.appendingPathComponent("wordmark")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let outputs: [(String, String, Bool)] = [
    ("VoxPalm-lockup-light.svg", "#2A1B15", true),  // 浅色背景用
    ("VoxPalm-lockup-dark.svg", "#FFF7F2", true),   // 深色背景用
    ("VoxPalm-wordmark-light.svg", "#2A1B15", false),
    ("VoxPalm-wordmark-dark.svg", "#FFF7F2", false),
]
for (name, color, icon) in outputs {
    let svg = lockup(textColor: color, withIcon: icon)
    let url = dir.appendingPathComponent(name)
    try! svg.write(to: url, atomically: true, encoding: .utf8)
    // 同时导出 2 倍大小的 PNG，方便直接用
    guard let img = NSImage(contentsOf: url) else { fatalError("渲染失败 \(name)") }
    let w = Int(img.size.width * 2), h = Int(img.size.height * 2)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: w, height: h)); NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: url.deletingPathExtension().appendingPathExtension("png"))
}
print("ok")
