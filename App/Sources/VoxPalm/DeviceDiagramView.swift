import AppKit
import SwiftUI
import VoxPalmEngine

/// 品牌色（brand/README.md 和 design/README.md）。
enum Brand {
    static let coralTop = Color(red: 1.0, green: 0.541, blue: 0.361)
    static let coralBottom = Color(red: 0.847, green: 0.353, blue: 0.188)
    static let inkTop = Color(red: 0.169, green: 0.157, blue: 0.251)
    static let inkBottom = Color(red: 0.090, green: 0.082, blue: 0.122)
    static let cream = Color(red: 1.0, green: 0.953, blue: 0.918)
    static let coral = LinearGradient(colors: [coralTop, coralBottom], startPoint: .top, endPoint: .bottom)
    static let ink = LinearGradient(colors: [inkTop, inkBottom], startPoint: .top, endPoint: .bottom)
    /// 小字用的珊瑚色：浅色底 #BF4B24，深色底 #FF9670
    static let coralText = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 1.0, green: 0.588, blue: 0.439, alpha: 1)
            : NSColor(red: 0.749, green: 0.294, blue: 0.141, alpha: 1)
    })
    /// 转写中的薰衣草色：浅色底 #6259A6，深色底 #A9A2E2
    static let lavender = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.663, green: 0.635, blue: 0.886, alpha: 1)
            : NSColor(red: 0.384, green: 0.349, blue: 0.651, alpha: 1)
    })
}

/// 示意图旁边一条标注要显示的内容。
struct DiagramCallout: Identifiable {
    let spot: DeviceDiagram.Spot
    let isBound: Bool
    let lines: [String]
    let reserved: [String]
    let isLearning: Bool

    var id: String { spot.id }

    /// 按标注宽度估算高度：每行字超出宽度就折成两行。
    func height(width: CGFloat) -> CGFloat {
        func rows(_ text: String, size: CGFloat) -> CGFloat {
            let textWidth = text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? size * 0.56 : size) }
            return min(2, max(1, (textWidth / max(width - 16, 40)).rounded(.up)))
        }
        let body = lines.reduce(CGFloat(0)) { $0 + rows($1, size: 10.5) * 13.5 }
        let notes = reserved.reduce(CGFloat(0)) { $0 + rows("设备占用 · " + $1, size: 10.5) * 13.5 }
        return 26 + body + notes
    }

    static func make(diagram: DeviceDiagram, buttons: [String: ButtonID], keyMap: KeyMap, reportsRelease: Bool, learning: String?) -> [DiagramCallout] {
        diagram.spots.map { spot in
            let button = buttons[spot.id]
            var lines: [String] = []
            if spot.id == learning {
                lines = ["请按一下设备上的这个键……"]
            } else if let button {
                for gesture in GestureKind.allCases where reportsRelease || gesture != .long {
                    if let binding = keyMap.binding(for: button, gesture: gesture), binding.action != .none {
                        lines.append("\(gesture.title)  \(binding.summary)")
                    }
                }
                if lines.isEmpty { lines = ["点一下设置"] }
            } else {
                lines = ["还没对上：点一下再按这个键"]
            }
            return DiagramCallout(spot: spot, isBound: button != nil, lines: lines, reserved: spot.reserved, isLearning: spot.id == learning)
        }
    }
}

/// 设备示意图 + 引线标注。点图上的键或旁边的标注来选中它。
struct DeviceDiagramView: View {
    let diagram: DeviceDiagram
    let callouts: [DiagramCallout]
    let pressed: Set<ButtonID>
    let buttons: [String: ButtonID]
    let selected: String?
    var onSelect: (String) -> Void = { _ in }
    /// 点了已经对上的键：在它的标注旁边弹出编辑小窗
    var editing: Binding<String?>?
    var editor: ((String) -> AnyView)?

    var body: some View {
        GeometryReader { geometry in
            let layout = DiagramLayout(diagram: diagram, callouts: callouts, size: geometry.size)
            ZStack(alignment: .topLeading) {
                DeviceArt(diagram: diagram, layout: layout, highlighted: highlighted)
                Canvas { context, _ in
                    for callout in callouts {
                        guard let path = layout.leader(for: callout.id) else { continue }
                        let active = callout.id == selected
                        context.stroke(path, with: .color(active ? Brand.coralTop : Color.gray.opacity(0.8)),
                                       style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round, lineJoin: .round))
                        if let end = layout.anchors[callout.id] {
                            context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                                         with: .color(active ? Brand.coralTop : Color.gray))
                        }
                    }
                }
                .allowsHitTesting(false)
                ForEach(diagram.spots) { spot in
                    let frame = layout.frame(spot.box).insetBy(dx: -3, dy: -3)
                    Color.clear
                        .contentShape(Rectangle())
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .onTapGesture { onSelect(spot.id) }
                        .help(spot.name)
                }
                ForEach(callouts) { callout in
                    if let frame = layout.labels[callout.id] {
                        CalloutLabel(callout: callout, selected: callout.id == selected)
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            .popover(isPresented: Binding(get: { editing?.wrappedValue == callout.id },
                                                          set: { if !$0 { editing?.wrappedValue = nil } }),
                                     arrowEdge: frame.midX < layout.device.midX ? .leading : .trailing) {
                                editor?(callout.id)
                            }
                            .offset(x: frame.minX, y: frame.minY)
                            .onTapGesture { onSelect(callout.id) }
                    }
                }
            }
        }
        .frame(height: DiagramLayout.preferredHeight(diagram: diagram, callouts: callouts))
    }

    private var highlighted: [String: DeviceArt.Highlight] {
        var result: [String: DeviceArt.Highlight] = [:]
        for spot in diagram.spots {
            if let button = buttons[spot.id], pressed.contains(button) {
                result[spot.id] = .pressed
            } else if spot.id == selected {
                result[spot.id] = .selected
            }
        }
        return result
    }
}

/// 算设备、标注、引线的位置。竖的设备标注在左右两边；宽的设备（展开的侧面、脚踏板、媒体键）标注在上下。
struct DiagramLayout {
    var device: CGRect = .zero
    /// 每毫米多少点
    var scale: CGFloat = 1
    var labels: [String: CGRect] = [:]
    var anchors: [String: CGPoint] = [:]
    private var labelSide: [String: Edge] = [:]

    /// 标注放上下：只有宽的设备、而且键横着排开（相邻两个键左右隔得够远）时才这样放，其他都放左右两边。
    static func usesRows(_ diagram: DeviceDiagram) -> Bool {
        guard diagram.isWide else { return false }
        let xs = diagram.spots.map(\.box.midX).sorted()
        return zip(xs, xs.dropFirst()).allSatisfy { $1 - $0 > diagram.width * 0.1 }
    }

    /// 设备在左右排标注时最多占多宽（相对整块宽度）
    static func maxDeviceFraction(_ diagram: DeviceDiagram) -> CGFloat { diagram.isWide ? 0.4 : 0.3 }

    static func preferredHeight(diagram: DeviceDiagram, callouts: [DiagramCallout], width: CGFloat = 650) -> CGFloat {
        if usesRows(diagram) {
            let labelWidth = min(240, (width - 16) / CGFloat(max(1, callouts.count > 3 ? (callouts.count + 1) / 2 : callouts.count)) - 8)
            let (top, bottom) = rowHeights(callouts.map(\.spot), heights: Dictionary(uniqueKeysWithValues: callouts.map { ($0.id, $0.height(width: labelWidth)) }))
            return (callouts.count > 3 ? top + bottom + 40 : bottom + 20) + 140
        }
        if diagram.id == "generic" { return max(260, CGFloat(callouts.count) * 64 + 40) }
        guard diagram.isWide else { return 460 }
        // 宽的展开图标注在左右：高度取设备高度和较长一列标注里大的那个。
        let deviceWidth = width * maxDeviceFraction(diagram)
        let deviceHeight = deviceWidth * diagram.height / diagram.width
        let labelWidth = min(230, (width - deviceWidth) / 2 - 44)
        let left = callouts.filter { spotIsLeft($0.spot, diagram) }.reduce(CGFloat(0)) { $0 + $1.height(width: labelWidth) + 6 }
        let right = callouts.filter { !spotIsLeft($0.spot, diagram) }.reduce(CGFloat(0)) { $0 + $1.height(width: labelWidth) + 6 }
        return max(deviceHeight, left, right) + 30
    }

    /// 标注放上下两排时，上排和下排各自最高的标注（只有一排时都算下排）
    private static func rowHeights(_ spots: [DeviceDiagram.Spot], heights: [String: CGFloat]) -> (top: CGFloat, bottom: CGFloat) {
        let sorted = spots.sorted { $0.box.midX < $1.box.midX }
        let twoRows = sorted.count > 3
        var top: CGFloat = 0, bottom: CGFloat = 0
        for (index, spot) in sorted.enumerated() {
            let height = heights[spot.id] ?? 40
            if twoRows && index % 2 == 0 { top = max(top, height) } else { bottom = max(bottom, height) }
        }
        return (top == 0 && twoRows ? 40 : top, bottom == 0 ? 40 : bottom)
    }

    private static func spotIsLeft(_ spot: DeviceDiagram.Spot, _ diagram: DeviceDiagram) -> Bool {
        spot.box.midX / diagram.width < 0.5
    }

    init(diagram: DeviceDiagram, callouts: [DiagramCallout], size: CGSize) {
        let aspect = diagram.width / diagram.height
        if Self.usesRows(diagram) {
            layoutRows(diagram: diagram, aspect: aspect, callouts: callouts, size: size)
        } else {
            layoutSides(diagram: diagram, aspect: aspect, callouts: callouts, size: size)
        }
        for spot in diagram.spots { anchors[spot.id] = anchorPoint(spot) }
    }

    /// 只画设备本体：整台设备按比例放进这块地方，居中。
    static func fitting(_ diagram: DeviceDiagram, in size: CGSize) -> DiagramLayout {
        var layout = DiagramLayout(diagram: diagram, callouts: [], size: size)
        let scale = max(0.01, min(size.width / diagram.width, size.height / diagram.height))
        layout.scale = scale
        layout.device = CGRect(x: (size.width - diagram.width * scale) / 2, y: (size.height - diagram.height * scale) / 2,
                               width: diagram.width * scale, height: diagram.height * scale)
        return layout
    }

    func frame(_ box: DeviceDiagram.Box) -> CGRect {
        CGRect(x: device.minX + box.x * scale, y: device.minY + box.y * scale, width: box.w * scale, height: box.h * scale)
    }

    private mutating func layoutSides(diagram: DeviceDiagram, aspect: Double, callouts: [DiagramCallout], size: CGSize) {
        let pad: CGFloat = 8
        var deviceHeight = size.height - pad * 2 - 8
        var deviceWidth = deviceHeight * aspect
        let maxWidth = size.width * Self.maxDeviceFraction(diagram)
        if deviceWidth > maxWidth {
            deviceWidth = maxWidth
            deviceHeight = deviceWidth / aspect
        }
        device = CGRect(x: (size.width - deviceWidth) / 2, y: (size.height - deviceHeight) / 2, width: deviceWidth, height: deviceHeight)
        scale = deviceWidth / diagram.width
        let labelWidth = min(230, (size.width - deviceWidth) / 2 - 44)
        let heights = Dictionary(uniqueKeysWithValues: callouts.map { ($0.id, $0.height(width: labelWidth)) })

        // 分左右：左半边的键标在左边，右半边的标在右边，正中间的两边轮流放。
        var left: [DeviceDiagram.Spot] = []
        var right: [DeviceDiagram.Spot] = []
        // 只给有标注的键排位置（引导里只标设了动作的键）
        let shown = Set(callouts.map(\.id))
        for spot in diagram.spots.sorted(by: { $0.box.midY < $1.box.midY }) where shown.isEmpty || shown.contains(spot.id) {
            let x = spot.box.midX / diagram.width
            if x < 0.42 { left.append(spot) } else if x > 0.58 { right.append(spot) }
            else if left.count <= right.count { left.append(spot) } else { right.append(spot) }
        }
        for (side, column) in [(Edge.leading, left), (Edge.trailing, right)] {
            let x = side == .leading ? pad : size.width - pad - labelWidth
            let wanted = column.map { spot in (spot, frame(spot.box).midY, heights[spot.id] ?? 40) }
            let tops = Self.stack(wanted.map { ($0.1, $0.2) }, min: pad, max: size.height - pad, gap: 6)
            for (index, item) in wanted.enumerated() {
                labels[item.0.id] = CGRect(x: x, y: tops[index], width: labelWidth, height: item.2)
                labelSide[item.0.id] = side
            }
        }
    }

    private mutating func layoutRows(diagram: DeviceDiagram, aspect: Double, callouts: [DiagramCallout], size: CGSize) {
        let pad: CGFloat = 8
        let shown = Set(callouts.map(\.id))
        let sorted = diagram.spots.filter { shown.isEmpty || shown.contains($0.id) }.sorted { $0.box.midX < $1.box.midX }
        let twoRows = sorted.count > 3
        let perRowCount = twoRows ? Int((Double(sorted.count) / 2).rounded(.up)) : sorted.count
        let rowLabelWidth = min(240, (size.width - pad * 2) / CGFloat(max(perRowCount, 1)) - 8)
        let heights = Dictionary(uniqueKeysWithValues: callouts.map { ($0.id, $0.height(width: rowLabelWidth)) })
        // 上下两排各按自己最高的标注留地方（只有下排有三行字时，上面不空出一大块）
        let (topRow, bottomRow) = Self.rowHeights(sorted, heights: heights)
        let deviceWidth = min(size.width * 0.82, (size.height - (twoRows ? topRow + bottomRow + 80 : bottomRow + 60)) * aspect)
        let deviceHeight = deviceWidth / aspect
        let top = twoRows ? pad + topRow + 34 : pad + 10
        device = CGRect(x: (size.width - deviceWidth) / 2, y: top, width: deviceWidth, height: deviceHeight)
        scale = deviceWidth / diagram.width
        let labelWidth = rowLabelWidth
        // 上下两排分别排：先对准各自的键，再左右推开不重叠，最后整排收进边界。
        for edge in twoRows ? [Edge.top, .bottom] : [.bottom] {
            let row = sorted.enumerated().filter { index, _ in !twoRows || (index % 2 == 0) == (edge == .top) }.map(\.element)
            var xs = row.map { frame($0.box).midX - labelWidth / 2 }
            for index in xs.indices {
                xs[index] = max(xs[index], index == 0 ? pad : xs[index - 1] + labelWidth + 8)
            }
            for index in xs.indices.reversed() {
                xs[index] = min(xs[index], index == xs.count - 1 ? size.width - pad - labelWidth : xs[index + 1] - labelWidth - 8)
            }
            for (index, spot) in row.enumerated() {
                let height = heights[spot.id] ?? 40
                let y = edge == .top ? device.minY - 30 - height : device.maxY + 30
                labels[spot.id] = CGRect(x: max(xs[index], pad), y: y, width: labelWidth, height: height)
                labelSide[spot.id] = edge
            }
        }
    }

    /// 让一列标注尽量对齐各自的键，又不互相重叠。
    static func stack(_ items: [(center: CGFloat, height: CGFloat)], min: CGFloat, max: CGFloat, gap: CGFloat) -> [CGFloat] {
        var tops = items.map { $0.center - $0.height / 2 }
        for index in tops.indices {
            let floor = index == 0 ? min : tops[index - 1] + items[index - 1].height + gap
            tops[index] = Swift.max(tops[index], floor)
        }
        for index in tops.indices.reversed() {
            let ceiling = index == tops.count - 1 ? max : tops[index + 1] - gap
            tops[index] = Swift.min(tops[index], ceiling - items[index].height)
        }
        return tops.map { Swift.max($0, min) }
    }

    /// 引线落在按键朝向标注的那一边。
    private func anchorPoint(_ spot: DeviceDiagram.Spot) -> CGPoint {
        let rect = frame(spot.box)
        switch labelSide[spot.id] {
        case .leading: return CGPoint(x: rect.minX, y: rect.midY)
        case .trailing: return CGPoint(x: rect.maxX, y: rect.midY)
        case .top: return CGPoint(x: rect.midX, y: rect.minY)
        case .bottom: return CGPoint(x: rect.midX, y: rect.maxY)
        case nil: return CGPoint(x: rect.midX, y: rect.midY)
        }
    }

    func leader(for id: String) -> Path? {
        guard let label = labels[id], let end = anchors[id], let side = labelSide[id] else { return nil }
        var path = Path()
        switch side {
        case .leading:
            let start = CGPoint(x: label.maxX + 3, y: label.minY + 14)
            path.move(to: start)
            path.addLine(to: CGPoint(x: min(device.minX - 16, end.x - 16), y: start.y))
            path.addLine(to: end)
        case .trailing:
            let start = CGPoint(x: label.minX - 3, y: label.minY + 14)
            path.move(to: start)
            path.addLine(to: CGPoint(x: max(device.maxX + 16, end.x + 16), y: start.y))
            path.addLine(to: end)
        case .top:
            let start = CGPoint(x: label.midX, y: label.maxY + 3)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: start.y + 10))
            path.addLine(to: CGPoint(x: end.x, y: min(end.y - 10, device.minY - 8)))
            path.addLine(to: end)
        case .bottom:
            let start = CGPoint(x: label.midX, y: label.minY - 3)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: start.y - 10))
            path.addLine(to: CGPoint(x: end.x, y: max(end.y + 10, device.maxY + 8)))
            path.addLine(to: end)
        }
        return path
    }
}

/// 按示意图的数据画设备：机身、接口、指示灯、按键，选中或按下的键叠珊瑚色。
struct DeviceArt: View {
    enum Highlight { case selected, pressed }

    let diagram: DeviceDiagram
    let layout: DiagramLayout
    let highlighted: [String: Highlight]
    /// 缩略图太小时不画键上的小图标和印的字
    var showsSymbols = true

    private static let aluminum = Gradient(colors: [Color(red: 0.93, green: 0.935, blue: 0.945), Color(red: 0.77, green: 0.78, blue: 0.80)])
    private static let graphite = Gradient(colors: [Color(red: 0.235, green: 0.235, blue: 0.255), Color(red: 0.115, green: 0.115, blue: 0.13)])
    private static let keyBlack = Color(red: 0.11, green: 0.11, blue: 0.12)
    private static let keyLight = Gradient(colors: [Color(red: 0.90, green: 0.905, blue: 0.915), Color(red: 0.78, green: 0.785, blue: 0.80)])
    private static let symbolOnDark = Color(red: 0.90, green: 0.90, blue: 0.92)
    private static let symbolOnLight = Color(red: 0.30, green: 0.30, blue: 0.33)

    var body: some View {
        Canvas { context, _ in
            context.drawLayer { layer in
                layer.addFilter(.shadow(color: .black.opacity(0.25), radius: 8, y: 4))
                for part in diagram.parts where part.style == .aluminum || part.style == .graphite {
                    draw(part.box, part.shape, part.style, symbol: nil, text: nil, in: &layer)
                }
            }
            for part in diagram.parts where part.style != .aluminum && part.style != .graphite {
                draw(part.box, part.shape, part.style, symbol: part.symbol, text: part.text, in: &context)
            }
            for spot in diagram.spots {
                draw(spot.box, spot.shape, spot.style, symbol: spot.symbol, text: nil, in: &context)
                if let highlight = highlighted[spot.id] {
                    let path = self.path(spot.box, spot.shape)
                    if highlight == .pressed {
                        context.drawLayer { glow in
                            glow.addFilter(.shadow(color: Brand.coralTop, radius: 7))
                            glow.fill(path, with: .color(Brand.coralTop.opacity(0.85)))
                        }
                    } else {
                        context.fill(path, with: .color(Brand.coralTop.opacity(spot.style == .zone ? 0.6 : 0.45)))
                    }
                    context.stroke(path, with: .color(Brand.coralTop), lineWidth: 1.8)
                    if let symbol = spot.symbol { drawSymbol(symbol, in: layout.frame(spot.box), color: .white, context: &context) }
                }
            }
        }
    }

    private func path(_ box: DeviceDiagram.Box, _ shape: DeviceDiagram.Shape) -> Path {
        let rect = layout.frame(box)
        switch shape {
        case let .rounded(radius): return Path(roundedRect: rect, cornerRadius: min(radius * layout.scale, min(rect.width, rect.height) / 2), style: .continuous)
        case .circle: return Path(ellipseIn: rect)
        case .capsule: return Path(roundedRect: rect, cornerRadius: min(rect.width, rect.height) / 2, style: .continuous)
        }
    }

    private func draw(_ box: DeviceDiagram.Box, _ shape: DeviceDiagram.Shape, _ style: DeviceDiagram.Style,
                      symbol: String?, text: String?, in context: inout GraphicsContext) {
        let rect = layout.frame(box)
        let path = self.path(box, shape)
        func vertical(_ gradient: Gradient) -> GraphicsContext.Shading {
            .linearGradient(gradient, startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY))
        }
        switch style {
        case .aluminum:
            context.fill(path, with: vertical(Self.aluminum))
            context.stroke(path, with: .color(Color(white: 0.6)), lineWidth: 0.8)
        case .graphite:
            context.fill(path, with: vertical(Self.graphite))
            context.stroke(path, with: .color(.white.opacity(0.14)), lineWidth: 0.8)
        case .clip:
            context.fill(path, with: .color(Color(white: 0.17)))
        case .blackKey:
            context.fill(path, with: .color(Self.keyBlack))
            context.stroke(path, with: .color(.white.opacity(0.1)), lineWidth: 0.8)
            if let symbol { drawSymbol(symbol, in: rect, color: Self.symbolOnDark, context: &context) }
        case .lightKey:
            context.fill(path, with: vertical(Self.keyLight))
            context.stroke(path, with: .color(Color(white: 0.55)), lineWidth: 0.8)
            if let symbol { drawSymbol(symbol, in: rect, color: Self.symbolOnLight, context: &context) }
        case .recordKey:
            context.fill(path, with: .color(Self.keyBlack))
            context.stroke(path, with: .color(Color(red: 0.93, green: 0.36, blue: 0.24)), lineWidth: max(1.5, rect.width * 0.14))
            context.fill(Path(ellipseIn: rect.insetBy(dx: rect.width * 0.32, dy: rect.height * 0.32)), with: .color(Color(red: 0.93, green: 0.36, blue: 0.24)))
        case .sideKey:
            context.fill(path, with: .color(Color(white: 0.5)))
            context.stroke(path, with: .color(Color(white: 0.3)), lineWidth: 0.6)
        case .recess:
            context.fill(path, with: .color(.black.opacity(0.28)))
            context.stroke(path, with: .color(.white.opacity(0.08)), lineWidth: 0.8)
        case .port:
            context.fill(path, with: .color(Color(white: 0.04)))
            context.stroke(path, with: .color(.white.opacity(0.18)), lineWidth: 0.6)
        case .led:
            context.fill(path, with: .color(Color(white: 0.52)))
        case .grille:
            // 网罩的缝顺着短边走：横的一块画竖缝，竖的一块画横缝。
            let vertical = rect.width >= rect.height
            let length = vertical ? rect.width : rect.height
            let count = max(3, Int(length / 5))
            for index in 0..<count {
                let t = (Double(index) + 0.5) / Double(count)
                var line = Path()
                if vertical {
                    let x = rect.minX + rect.width * t
                    line.move(to: CGPoint(x: x, y: rect.minY))
                    line.addLine(to: CGPoint(x: x, y: rect.maxY))
                } else {
                    let y = rect.minY + rect.height * t
                    line.move(to: CGPoint(x: rect.minX, y: y))
                    line.addLine(to: CGPoint(x: rect.maxX, y: y))
                }
                context.stroke(line, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
            }
        case .mark:
            if let symbol {
                drawSymbol(symbol, in: rect, color: Color(white: 0.45), context: &context)
            } else if let text {
                // 小标记（比如 NFC 的 N）：细边框 + 一个字
                context.stroke(path, with: .color(Color(white: 0.4)), lineWidth: 0.8)
                context.draw(Text(text).font(.system(size: max(5, rect.height * 0.62), weight: .semibold)).foregroundStyle(Color(white: 0.4)),
                             at: CGPoint(x: rect.midX, y: rect.midY))
            } else {
                context.fill(path, with: .color(Color(white: 0.45)))
            }
        case .printLight, .printDark:
            guard showsSymbols else { break }
            let color = style == .printLight ? Color.white.opacity(0.88) : Color(white: 0.32)
            if let text, let mark = DiagramMarks.shape(text) {
                // 官方版登记了真的品牌标志图形就画标志，开源版照旧印字。
                context.fill(Path(mark.path(in: rect)), with: .color(color))
            } else if let text {
                context.draw(Text(text).font(.system(size: max(5, rect.height * 0.95), weight: .semibold)).foregroundStyle(color),
                             at: CGPoint(x: rect.midX, y: rect.midY))
            }
        case .dot:
            context.fill(path, with: .color(.white.opacity(0.92)))
        case .caption:
            if let text {
                // 字号固定 10.5；图缩得比字还窄（选设备的转盘里）就按宽度把字缩小，免得两头被切掉
                let full = context.resolve(Text(text).font(.system(size: 10.5))).measure(in: CGSize(width: CGFloat.infinity, height: .infinity)).width
                let size = full > rect.width ? max(7, 10.5 * rect.width / full) : 10.5
                context.draw(Text(text).font(.system(size: size)).foregroundStyle(.secondary), at: CGPoint(x: rect.midX, y: rect.midY))
            }
        case .zone:
            if let symbol { drawSymbol(symbol, in: rect, color: Self.symbolOnDark, context: &context) }
        }
    }

    /// 按键上的图标：和实物一样细、占键面三分之一左右。
    private func drawSymbol(_ name: String, in rect: CGRect, color: Color, context: inout GraphicsContext) {
        guard showsSymbols else { return }
        let side = min(rect.width, rect.height)
        let text = Text(Image(systemName: name)).font(.system(size: max(6, side * 0.32), weight: .regular)).foregroundStyle(color)
        context.draw(text, at: CGPoint(x: rect.midX, y: rect.midY))
    }
}

/// 旁边的说明卡片。
struct CalloutLabel: View {
    let callout: DiagramCallout
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(callout.spot.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            ForEach(callout.lines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 10.5))
                    .foregroundStyle(callout.isLearning ? AnyShapeStyle(Brand.coralText) : callout.isBound ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .truncationMode(.tail)
            }
            ForEach(callout.reserved, id: \.self) { note in
                Text("设备占用 · \(note)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // 动作一改，标注闪一下珊瑚色（设计稿 labflash）
        .keyframeAnimator(initialValue: 0.0, trigger: callout.lines) { content, glow in
            content.background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Brand.coralTop.opacity(0.4 * glow)))
        } keyframes: { _ in
            LinearKeyframe(1.0, duration: 0.05)
            CubicKeyframe(0.0, duration: 0.75)
        }
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Brand.coralTop.opacity(0.12) : Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Brand.coralBottom : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}
