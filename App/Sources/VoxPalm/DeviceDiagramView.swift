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
}

/// 示意图旁边一条标注要显示的内容。
struct DiagramCallout: Identifiable {
    let spot: DeviceDiagram.Spot
    let isBound: Bool
    let lines: [String]
    let reserved: [String]
    let isLearning: Bool

    var id: String { spot.id }
    var height: CGFloat { 24 + 14 * CGFloat(max(lines.count, 1) + reserved.count) }

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

    var body: some View {
        GeometryReader { geometry in
            let layout = DiagramLayout(body: diagram.body, spots: diagram.spots, callouts: callouts, size: geometry.size)
            ZStack(alignment: .topLeading) {
                DeviceBody(body: diagram.body)
                    .frame(width: layout.device.width, height: layout.device.height)
                    .offset(x: layout.device.minX, y: layout.device.minY)
                Canvas { context, _ in
                    for callout in callouts {
                        guard let path = layout.leader(for: callout.id) else { continue }
                        let active = callout.id == selected
                        context.stroke(path, with: .color(active ? Brand.coralTop : Color.gray.opacity(0.75)),
                                       style: StrokeStyle(lineWidth: active ? 1.5 : 1, lineCap: .round, lineJoin: .round))
                        if let end = layout.anchors[callout.id] {
                            context.fill(Path(ellipseIn: CGRect(x: end.x - 2.5, y: end.y - 2.5, width: 5, height: 5)),
                                         with: .color(active ? Brand.coralTop : Color.gray))
                        }
                    }
                }
                ForEach(diagram.spots) { spot in
                    let frame = layout.spotFrame(spot)
                    SpotShapeView(spot: spot, device: layout.device,
                                  state: spotState(spot))
                        .frame(width: frame.width, height: frame.height)
                        .offset(x: frame.minX, y: frame.minY)
                        .onTapGesture { onSelect(spot.id) }
                        .help(spot.name)
                }
                ForEach(callouts) { callout in
                    if let frame = layout.labels[callout.id] {
                        CalloutLabel(callout: callout, selected: callout.id == selected)
                            .frame(width: frame.width, height: frame.height, alignment: .topLeading)
                            .offset(x: frame.minX, y: frame.minY)
                            .onTapGesture { onSelect(callout.id) }
                    }
                }
            }
        }
        .frame(height: DiagramLayout.preferredHeight(body: diagram.body, callouts: callouts))
    }

    private func spotState(_ spot: DeviceDiagram.Spot) -> SpotShapeView.State {
        if let button = buttons[spot.id], pressed.contains(button) { return .pressed }
        if spot.id == selected { return .selected }
        return buttons[spot.id] == nil ? .unbound : .normal
    }
}

/// 算设备、标注、引线的位置。竖的设备标注在左右两边；宽的设备（脚踏板、媒体键）标注在上下。
struct DiagramLayout {
    var device: CGRect = .zero
    var labels: [String: CGRect] = [:]
    var anchors: [String: CGPoint] = [:]
    private var labelSide: [String: Edge] = [:]

    static func preferredHeight(body: DeviceDiagram.Body, callouts: [DiagramCallout]) -> CGFloat {
        if body.isWide {
            let row = (callouts.map(\.height).max() ?? 40)
            return (callouts.count > 3 ? row * 2 + 40 : row + 20) + 150
        }
        return body == .generic ? max(260, CGFloat(callouts.count) * 64 + 40) : 440
    }

    init(body: DeviceDiagram.Body, spots: [DeviceDiagram.Spot], callouts: [DiagramCallout], size: CGSize) {
        let heights = Dictionary(uniqueKeysWithValues: callouts.map { ($0.id, $0.height) })
        if body.isWide {
            layoutWide(body: body, spots: spots, heights: heights, size: size)
        } else {
            layoutTall(body: body, spots: spots, heights: heights, size: size)
        }
        for spot in spots { anchors[spot.id] = anchorPoint(spot) }
    }

    private mutating func layoutTall(body: DeviceDiagram.Body, spots: [DeviceDiagram.Spot], heights: [String: CGFloat], size: CGSize) {
        let pad: CGFloat = 8
        var deviceHeight = size.height - pad * 2 - 8
        var deviceWidth = deviceHeight * body.aspect
        if deviceWidth > size.width * 0.3 {
            deviceWidth = size.width * 0.3
            deviceHeight = deviceWidth / body.aspect
        }
        device = CGRect(x: (size.width - deviceWidth) / 2, y: (size.height - deviceHeight) / 2, width: deviceWidth, height: deviceHeight)
        let labelWidth = min(230, (size.width - deviceWidth) / 2 - 44)

        // 分左右：左半边的键标在左边，右半边的标在右边，正中间的两边轮流放。
        var left: [DeviceDiagram.Spot] = []
        var right: [DeviceDiagram.Spot] = []
        for spot in spots.sorted(by: { $0.y < $1.y }) {
            if spot.x < 0.45 { left.append(spot) } else if spot.x > 0.55 { right.append(spot) }
            else if left.count <= right.count { left.append(spot) } else { right.append(spot) }
        }
        for (side, column) in [(Edge.leading, left), (Edge.trailing, right)] {
            let x = side == .leading ? pad : size.width - pad - labelWidth
            let wanted = column.map { spot in (spot, device.minY + spot.y * device.height, heights[spot.id] ?? 40) }
            let tops = Self.stack(wanted.map { ($0.1, $0.2) }, min: pad, max: size.height - pad, gap: 6)
            for (index, item) in wanted.enumerated() {
                labels[item.0.id] = CGRect(x: x, y: tops[index], width: labelWidth, height: item.2)
                labelSide[item.0.id] = side
            }
        }
    }

    private mutating func layoutWide(body: DeviceDiagram.Body, spots: [DeviceDiagram.Spot], heights: [String: CGFloat], size: CGSize) {
        let pad: CGFloat = 8
        let sorted = spots.sorted { $0.x < $1.x }
        let twoRows = sorted.count > 3
        let rowHeight = heights.values.max() ?? 40
        let deviceWidth = min(size.width * 0.82, (size.height - (twoRows ? rowHeight * 2 + 80 : rowHeight + 60)) * body.aspect)
        let deviceHeight = deviceWidth / body.aspect
        let top = twoRows ? pad + rowHeight + 34 : pad + 10
        device = CGRect(x: (size.width - deviceWidth) / 2, y: top, width: deviceWidth, height: deviceHeight)
        let perRow = twoRows ? Int((Double(sorted.count) / 2).rounded(.up)) : sorted.count
        let labelWidth = min(240, (size.width - pad * 2) / CGFloat(perRow) - 8)
        // 上下两排分别排：先对准各自的键，再左右推开不重叠，最后整排收进边界。
        for edge in twoRows ? [Edge.top, .bottom] : [.bottom] {
            let row = sorted.enumerated().filter { index, _ in !twoRows || (index % 2 == 0) == (edge == .top) }.map(\.element)
            var xs = row.map { device.minX + $0.x * device.width - labelWidth / 2 }
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

    func spotFrame(_ spot: DeviceDiagram.Spot) -> CGRect {
        let center = CGPoint(x: device.minX + spot.x * device.width, y: device.minY + spot.y * device.height)
        let d = spot.size * device.width
        let size: CGSize
        switch spot.shape {
        case .round, .arrow, .pad: size = CGSize(width: d, height: d)
        case .pill: size = spot.isOnSide ? CGSize(width: 7, height: d * 2.6) : CGSize(width: d * 1.5, height: d * 0.62)
        case .pedal: size = CGSize(width: d, height: device.height * 0.72)
        case .key: size = CGSize(width: d, height: device.height * 0.62)
        }
        return CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }

    /// 引线落在按键的哪个点上：侧键落在外侧，其他落在朝向标注的那一边。
    private func anchorPoint(_ spot: DeviceDiagram.Spot) -> CGPoint {
        let frame = spotFrame(spot)
        switch labelSide[spot.id] {
        case .leading: return CGPoint(x: frame.minX, y: frame.midY)
        case .trailing: return CGPoint(x: frame.maxX, y: frame.midY)
        case .top: return CGPoint(x: frame.midX, y: frame.minY)
        case .bottom: return CGPoint(x: frame.midX, y: frame.maxY)
        case nil: return CGPoint(x: frame.midX, y: frame.midY)
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
            path.addLine(to: CGPoint(x: end.x, y: end.y - 10))
            path.addLine(to: end)
        case .bottom:
            let start = CGPoint(x: label.midX, y: label.minY - 3)
            path.move(to: start)
            path.addLine(to: CGPoint(x: start.x, y: start.y - 10))
            path.addLine(to: CGPoint(x: end.x, y: end.y + 10))
            path.addLine(to: end)
        }
        return path
    }
}

/// 设备外壳：墨色渐变 + 每类设备的一点细节（方向键圆环、麦克风网罩）。
struct DeviceBody: View {
    let body_: DeviceDiagram.Body

    init(body: DeviceDiagram.Body) {
        body_ = body
    }

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                shell(w: w, h: h)
                switch body_ {
                case .remote:
                    Circle()
                        .fill(Color.white.opacity(0.05))
                        .overlay(Circle().stroke(Brand.cream.opacity(0.16), lineWidth: 1))
                        .frame(width: w * 0.86, height: w * 0.86)
                        .position(x: w * 0.5, y: h * 0.335)
                case .micTransmitter:
                    grille(w: w, h: h)
                    Circle().fill(Brand.cream.opacity(0.35)).frame(width: w * 0.05).position(x: w * 0.5, y: h * 0.47)
                case .presenter:
                    Capsule().fill(Brand.coralTop.opacity(0.35)).frame(width: w * 0.36, height: h * 0.025).position(x: w * 0.5, y: h * 0.035)
                default:
                    EmptyView()
                }
            }
        }
    }

    private var cornerFraction: CGFloat {
        switch body_ {
        case .remote, .presenter: return 0.48
        case .touchRemote: return 0.32
        case .micTransmitter: return 0.2
        case .footPedal: return 0.05
        case .mediaKeys: return 0.025
        case .generic: return 0.25
        }
    }

    private func shell(w: CGFloat, h: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: w * cornerFraction, style: .continuous)
        return shape
            .fill(Brand.ink)
            .overlay(shape.stroke(Color.white.opacity(0.14), lineWidth: 1))
            .shadow(color: .black.opacity(0.28), radius: 10, y: 5)
    }

    private func grille(w: CGFloat, h: CGFloat) -> some View {
        let dot = w * 0.045
        return VStack(spacing: dot * 0.9) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: dot * 0.9) {
                    ForEach(0..<6, id: \.self) { _ in Circle().fill(Brand.cream.opacity(0.18)).frame(width: dot, height: dot) }
                }
            }
        }
        .position(x: w * 0.5, y: h * 0.22)
    }
}

/// 一个按键的样子。
struct SpotShapeView: View {
    enum State { case normal, unbound, selected, pressed }

    let spot: DeviceDiagram.Spot
    let device: CGRect
    let state: State

    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            ZStack {
                shape
                    .fill(fill)
                    .overlay(shape.stroke(stroke, style: StrokeStyle(lineWidth: state == .selected ? 1.5 : 1, dash: state == .unbound ? [3, 2.5] : [])))
                    .shadow(color: state == .pressed ? Brand.coralTop.opacity(0.9) : .clear, radius: 8)
                if spot.shape == .pedal {
                    VStack(spacing: h * 0.07) {
                        ForEach(0..<4, id: \.self) { _ in Capsule().fill(Brand.cream.opacity(0.14)).frame(width: w * 0.6, height: 2) }
                    }
                }
                if let symbol = spot.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: max(7, min(w, h) * (spot.shape == .key ? 0.32 : 0.42)), weight: .semibold))
                        .foregroundStyle(symbolColor)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var shape: AnyShape {
        switch spot.shape {
        case .round, .arrow, .pad: return AnyShape(Circle())
        case .pill: return AnyShape(Capsule())
        case .pedal: return AnyShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        case .key: return AnyShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .pressed, .selected:
            // 大块的触摸板、踏板选中时只淡淡地染色，不然整块变成珊瑚色太重。
            return spot.shape == .pad || spot.shape == .pedal ? AnyShapeStyle(Brand.coralTop.opacity(0.32)) : AnyShapeStyle(Brand.coral)
        case .normal, .unbound:
            return AnyShapeStyle(Color.white.opacity(spot.shape == .pad ? 0.07 : 0.11))
        }
    }

    private var stroke: Color {
        switch state {
        case .pressed, .selected: return Brand.coralTop
        case .normal: return Brand.cream.opacity(0.5)
        case .unbound: return Brand.cream.opacity(0.35)
        }
    }

    private var symbolColor: Color {
        if state == .selected || state == .pressed { return .white }
        // 录制键用品牌的珊瑚色圆点。
        return spot.symbol == "circle.fill" ? Brand.coralTop : Brand.cream.opacity(0.85)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            ForEach(callout.reserved, id: \.self) { note in
                Text("设备占用 · \(note)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(selected ? Brand.coralTop.opacity(0.12) : Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).stroke(selected ? Brand.coralBottom : Color.primary.opacity(0.1), lineWidth: selected ? 1.5 : 1))
        .contentShape(Rectangle())
    }
}
