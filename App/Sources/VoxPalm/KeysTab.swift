import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxPalmEngine

/// 按键页：上面是设备示意图，下面一张表（行是键，列是单击 / 双击 / 长按，点格子就地设），再下面是手势时间。
struct KeysPane: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSpot: String?
    @State private var confirmPreset = false

    var body: some View {
        PaneScaffold(title: "按键") {
            Button(model.learningSpot == nil ? "学一个键" : "取消学键") {
                if model.learningSpot == nil { learnNew() } else { model.cancelLearning() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.activeDevice == nil)
        } content: {
            Form {
                if let device = model.activeDevice {
                    let resolved = model.diagram(for: device)
                    Section {
                        if !resolved.isFixed {
                            Picker("外形", selection: Binding(get: { resolved.diagram.id }, set: { model.setDiagram($0, for: device.id) })) {
                                ForEach(DeviceDiagram.choices) { Text($0.title).tag($0.id) }
                                if resolved.diagram.id == DeviceDiagram.mediaKeys.id {
                                    Text(DeviceDiagram.mediaKeys.title).tag(DeviceDiagram.mediaKeys.id)
                                }
                            }
                        }
                        if model.learningSpot != nil {
                            LearnBar(deviceName: device.name, spotName: resolved.diagram.spots.first { $0.id == model.learningSpot }?.name) {
                                model.cancelLearning()
                            }
                        }
                        DeviceDiagramView(
                            diagram: resolved.diagram,
                            callouts: DiagramCallout.make(diagram: resolved.diagram, buttons: resolved.buttons, keyMap: model.config.keyMap,
                                                          reportsRelease: resolved.reportsRelease, learning: model.learningSpot),
                            pressed: model.pressedButtons,
                            buttons: resolved.buttons,
                            selected: selectedSpot,
                            onSelect: { spot in
                                selectedSpot = spot
                                if resolved.buttons[spot] == nil { model.startLearning(spot: spot) }
                            }
                        )
                    } header: {
                        HStack {
                            Text("\(device.name) · 键位方案「\(model.config.keyMap.name)」")
                            Spacer()
                            Text("按 App 切换方案 · PRO").font(.caption.weight(.semibold)).foregroundStyle(Brand.coralText)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(Brand.coralTop.opacity(0.14)))
                        }
                    } footer: {
                        FootNote((resolved.diagram.note.map { $0 + "。" } ?? "") + (resolved.isFixed
                             ? "照产品图画的示意图。按设备上的键，图上对应的键会亮。"
                             : "照产品图画的示意图。图上还没对上的键，点一下再按设备上的同一个键；按键时图上会亮。"))
                    }

                    Section {
                        KeyTable(rows: rows(resolved: resolved, device: device), reportsRelease: resolved.reportsRelease,
                                 selectedSpot: $selectedSpot)
                        HStack {
                            Text(tableNote).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if !AIPreset.bindings(for: resolved).isEmpty {
                                Button("套用「AI 编程」预设…") { confirmPreset = true }
                            }
                        }
                    }
                    .alert("套用「AI 编程」预设？", isPresented: $confirmPreset) {
                        Button("套用") { for binding in AIPreset.bindings(for: resolved) { model.setBinding(binding) } }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(AIPreset.description(for: resolved))
                    }
                } else {
                    Section {
                        Text("先在「设备」里选一个控制设备。").foregroundStyle(.secondary)
                        Button("去选设备") { model.openSettings(.devices) }
                    }
                }

                Section("手势时间") {
                    GestureRuler(doubleTap: model.config.timing.doubleTapWindow, longPress: model.config.timing.longPressThreshold)
                        .frame(height: 150)
                    LabeledContent("双击间隔") {
                        Slider(value: model.binding(\.timing.doubleTapWindow), in: 0.15...0.6, step: 0.05)
                        Text(String(format: "%.2f 秒", model.config.timing.doubleTapWindow)).monospacedDigit().frame(width: 60)
                    }
                    LabeledContent("长按多久算长按") {
                        Slider(value: model.binding(\.timing.longPressThreshold), in: 0.25...1.5, step: 0.05)
                        Text(String(format: "%.2f 秒", model.config.timing.longPressThreshold)).monospacedDigit().frame(width: 60)
                    }
                }

                Section("导入导出") {
                    HStack {
                        Button("导出设置…") { exportConfig() }
                        Button("导入设置…") { importConfig() }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .onChange(of: model.activeDevice?.id) { _, _ in selectedSpot = nil }
    }

    /// 「学一个键」：选中了图上还没对上的键就学它，否则学一个图上没有的键（加到表里）。
    private func learnNew() {
        guard let device = model.activeDevice else { return }
        let resolved = model.diagram(for: device)
        if let spot = selectedSpot, resolved.buttons[spot] == nil {
            model.startLearning(spot: spot)
        } else {
            model.startLearning(spot: "+")
        }
    }

    private var tableNote: String {
        let doubles = model.config.keyMap.bindings.filter { $0.gesture == .double && $0.action != .none }.map(\.buttonLabel)
        if let first = doubles.first {
            return "「\(first)」设了双击，所以它的单击要等双击间隔过去才生效；没设双击的键，单击立刻生效。"
        }
        return "没设双击的键，单击立刻生效。"
    }

    /// 表里的行：图上对上了的键（按图上的顺序），再加图上没有、但学过或设过的键。
    private func rows(resolved: AppModel.ResolvedDiagram, device: ControlDevice) -> [KeyTable.Row] {
        var rows: [KeyTable.Row] = []
        var seen = Set<ButtonID>()
        for spot in resolved.diagram.spots {
            guard let button = resolved.buttons[spot.id], seen.insert(button).inserted else { continue }
            rows.append(.init(id: spot.id, name: spot.name, button: button, spotID: spot.id, reserved: spot.reserved))
        }
        for learned in model.config.deviceLayouts[device.id]?.learned ?? [] where seen.insert(learned.button).inserted {
            rows.append(.init(id: learned.button.rawValue, name: learned.label, button: learned.button, spotID: nil, reserved: []))
        }
        for binding in model.config.keyMap.bindings where seen.insert(binding.button).inserted {
            rows.append(.init(id: binding.button.rawValue, name: binding.buttonLabel, button: binding.button, spotID: nil, reserved: []))
        }
        return rows
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "掌声设置.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportConfig(to: url)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.importConfig(from: url)
    }
}

/// 学键时的提示条。
struct LearnBar: View {
    let deviceName: String
    let spotName: String?
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            HUDDot(state: .armed(since: Date()))
            Text(spotName.map { "请按一下「\(deviceName)」上的「\($0)」……" } ?? "请按一下「\(deviceName)」上的键……")
            Spacer()
            Button("取消", action: cancel).controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Brand.coralTop.opacity(0.12)))
    }
}

/// 键位表：行是键，三列是单击、双击、长按。空格子点一下就能设，设过的点一下就改。
struct KeyTable: View {
    struct Row: Identifiable {
        let id: String
        let name: String
        let button: ButtonID
        let spotID: String?
        let reserved: [String]
    }

    @Environment(AppModel.self) private var model
    let rows: [Row]
    let reportsRelease: Bool
    @Binding var selectedSpot: String?
    @State private var editing: String?

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("按键").font(.caption).foregroundStyle(.secondary)
                ForEach(GestureKind.allCases, id: \.self) { gesture in
                    HStack(spacing: 5) {
                        GestureGlyph(gesture: gesture).opacity(0.8)
                        Text(gesture.title)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider().gridCellUnsizedAxes(.horizontal)
            if rows.isEmpty {
                Text("还没有键。点图上的键对上，或者点右上角「学一个键」。").font(.callout).foregroundStyle(.secondary)
                    .gridCellColumns(4)
            }
            ForEach(rows) { row in
                GridRow {
                    Button { selectedSpot = row.spotID } label: { KeyChip(name: row.name) }
                        .buttonStyle(.plain)
                    ForEach(GestureKind.allCases, id: \.self) { gesture in
                        cell(row, gesture)
                    }
                }
                .background(row.spotID != nil && row.spotID == selectedSpot ? Brand.coralTop.opacity(0.08) : .clear)
            }
        }
    }

    @ViewBuilder
    private func cell(_ row: Row, _ gesture: GestureKind) -> some View {
        let binding = model.binding(for: row.button, gesture: gesture)
        let key = "\(row.id)|\(gesture.rawValue)"
        let reserved = row.reserved.first { $0.hasPrefix(gesture.title) }
        if gesture == .long && !reportsRelease {
            KeyCellBox(style: .disabled) { Text("读不到松开").foregroundStyle(.tertiary) }
                .help("这台设备只有短按、没有松开，做不了长按")
        } else if binding == nil, let reserved {
            KeyCellBox(style: .reserved) {
                Label("固件占用", systemImage: "lock").foregroundStyle(.secondary)
            }
            .help("设备自己占用：\(reserved)")
        } else {
            Button {
                editing = key
                selectedSpot = row.spotID ?? selectedSpot
            } label: {
                if let binding, binding.action != .none {
                    KeyCellBox(style: binding.startsVoice ? .voice : .filled) {
                        HStack(spacing: 6) {
                            if binding.startsVoice { Circle().fill(Brand.coral).frame(width: 8, height: 8) }
                            Text(binding.summary).lineLimit(1)
                                .foregroundStyle(binding.startsVoice ? AnyShapeStyle(Brand.coralText) : AnyShapeStyle(.primary))
                        }
                    }
                } else {
                    KeyCellBox(style: .empty) { Label("设置", systemImage: "plus").foregroundStyle(.secondary) }
                }
            }
            .buttonStyle(.plain)
            .popover(isPresented: Binding(get: { editing == key }, set: { if !$0 { editing = nil } }), arrowEdge: .bottom) {
                ActionEditor(button: row.button, buttonName: row.name, gesture: gesture)
                    .environment(model)
            }
        }
    }
}

/// 表格里的一格：设过的实心、语音动作珊瑚色、空的虚线框、固件占用斜纹、读不到松开灰字。
struct KeyCellBox<Content: View>: View {
    enum Style { case filled, voice, empty, reserved, disabled }

    let style: Style
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .font(.callout)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
            .background(background)
            .overlay(border)
            .contentShape(Rectangle())
    }

    @ViewBuilder
    private var background: some View {
        switch style {
        case .filled: RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06))
        case .voice: RoundedRectangle(cornerRadius: 7).fill(Brand.coralTop.opacity(0.16))
        case .reserved:
            RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.03))
                .overlay(Hatch().stroke(Color.primary.opacity(0.08), lineWidth: 1).clipShape(RoundedRectangle(cornerRadius: 7)))
        case .empty, .disabled: Color.clear
        }
    }

    @ViewBuilder
    private var border: some View {
        switch style {
        case .empty: RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.2), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        case .disabled: RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08), lineWidth: 1)
        default: EmptyView()
        }
    }
}

/// 斜纹（固件占用的格子）。
struct Hatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += 8
        }
        return path
    }
}

/// 手势时间尺：拖滑块时看得到双击间隔和长按线怎么动。
struct GestureRuler: View {
    let doubleTap: Double
    let longPress: Double

    private let span = 1.5
    private static let lavender = Color(red: 0.55, green: 0.52, blue: 0.85)

    var body: some View {
        GeometryReader { geometry in
            let left: CGFloat = 46
            let width = geometry.size.width - left - 8
            let x = { (t: Double) in left + width * CGFloat(t / span) }
            let rowY: [CGFloat] = [40, 70, 100]
            ZStack(alignment: .topLeading) {
                ForEach(0..<3, id: \.self) { index in
                    Text(["单击", "双击", "长按"][index]).font(.caption).foregroundStyle(.secondary)
                        .position(x: 18, y: rowY[index])
                    Capsule().fill(Color.primary.opacity(0.05)).frame(width: width, height: 14).position(x: left + width / 2, y: rowY[index])
                }
                // 单击：一下
                bar(x(0), x(0.12), y: rowY[0], color: .secondary)
                // 双击：间隔内第二下
                bar(x(0), x(0.1), y: rowY[1], color: .secondary)
                bar(x(doubleTap * 0.65), x(doubleTap * 0.65 + 0.1), y: rowY[1], color: .secondary)
                // 长按：过了长按线变成「按住说话」
                bar(x(0), x(longPress), y: rowY[2], color: .secondary)
                ZStack {
                    Capsule().fill(Brand.coral)
                    Text("按住说话").font(.caption2.weight(.semibold)).foregroundStyle(.white)
                }
                .frame(width: max(0, x(min(span - 0.05, longPress + 0.45)) - x(longPress)), height: 14)
                .position(x: (x(longPress) + x(min(span - 0.05, longPress + 0.45))) / 2, y: rowY[2])
                Text("没有第二下 → 单击").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .position(x: x(doubleTap) + 60, y: rowY[0])
                Text("间隔内第二下 → 双击").font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .position(x: x(doubleTap) + 66, y: rowY[1])
                marker(x(doubleTap), color: Self.lavender, label: String(format: "双击间隔 %.2f 秒", doubleTap), labelY: 12, top: 26, bottom: 112)
                marker(x(longPress), color: Brand.coralBottom, label: String(format: "长按 %.2f 秒", longPress), labelY: 12, top: 26, bottom: 112)
                ForEach([0.0, 0.5, 1.0, 1.5], id: \.self) { t in
                    Text(t == 1.5 ? "1.5 秒" : String(format: "%g", t)).font(.caption2).foregroundStyle(.tertiary)
                        .position(x: x(t) - (t == 1.5 ? 14 : 0), y: 130)
                }
            }
        }
    }

    private func bar(_ from: CGFloat, _ to: CGFloat, y: CGFloat, color: Color) -> some View {
        Capsule().fill(color.opacity(0.45)).frame(width: max(4, to - from), height: 14).position(x: (from + to) / 2, y: y)
    }

    private func marker(_ x: CGFloat, color: Color, label: String, labelY: CGFloat, top: CGFloat, bottom: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(color).fixedSize()
                .position(x: x, y: labelY)
        }
    }
}

/// 「AI 编程」预设：上下键直接切对话；确认键长按按住说话、单击回车发送。只设已经对上的键。
enum AIPreset {
    struct Item {
        let spot: String
        let gesture: GestureKind
        let action: Action
        var talkAfter = false
        var send = false
    }

    /// 按键位名字设：哪台设备有这个键就设，没有就跳过。
    static let items: [Item] = [
        // 遥控器：上下切对话，确认键长按说话、单击发送，返回 / 主页 / TV 打开 AI 工具
        Item(spot: "up", gesture: .single, action: .switchChat(.previous)),
        Item(spot: "down", gesture: .single, action: .switchChat(.next)),
        Item(spot: "ok", gesture: .long, action: .pushToTalk),
        Item(spot: "ok", gesture: .single, action: .sendReturn),
        Item(spot: "voice", gesture: .single, action: .toggleDictation),
        Item(spot: "back", gesture: .single, action: .menuCommand(AIToolProfile.claude.open)),
        Item(spot: "home", gesture: .single, action: .menuCommand(AIToolProfile.codex.open)),
        Item(spot: "tv", gesture: .single, action: .menuCommand(AIToolProfile.codex.open)),
        // 翻页笔、媒体键：上一个 / 下一个切对话
        Item(spot: "previous", gesture: .single, action: .switchChat(.previous)),
        Item(spot: "next", gesture: .single, action: .switchChat(.next)),
        Item(spot: "screen", gesture: .single, action: .sendReturn),
        Item(spot: "laser", gesture: .long, action: .pushToTalk),
        Item(spot: "playPause", gesture: .long, action: .pushToTalk),
        Item(spot: "playPause", gesture: .single, action: .sendReturn),
        // 脚踏板
        Item(spot: "left", gesture: .single, action: .switchChat(.previous)),
        Item(spot: "middle", gesture: .long, action: .pushToTalk),
        Item(spot: "middle", gesture: .single, action: .sendReturn),
        Item(spot: "right", gesture: .single, action: .switchChat(.next)),
        // 无线麦：录制键开始 / 结束说话，连接键发送
        Item(spot: "record", gesture: .single, action: .toggleDictation),
        Item(spot: "link", gesture: .single, action: .sendReturn),
    ]

    static func bindings(for resolved: AppModel.ResolvedDiagram) -> [KeyBinding] {
        // 遥控器的左右键留给用户自己设，不跟脚踏板的左右踏板混用。
        let isPedal = resolved.diagram.id == DeviceDiagram.footPedal.id
        return items.filter { isPedal || !["left", "right"].contains($0.spot) }.compactMap { item in
            guard let button = resolved.buttons[item.spot],
                  let spot = resolved.diagram.spots.first(where: { $0.id == item.spot }),
                  resolved.reportsRelease || item.gesture != .long else { return nil }
            return KeyBinding(button: button, buttonLabel: spot.name, gesture: item.gesture, action: item.action,
                              talkAfter: item.talkAfter ? true : nil, sendAfterTalk: item.send ? true : nil)
        }
    }

    static func description(for resolved: AppModel.ResolvedDiagram) -> String {
        let lines = bindings(for: resolved).map { "\($0.buttonLabel) \($0.gesture.title)：\($0.summary)" }
        return "会覆盖这些键现在的设置：\n" + lines.joined(separator: "\n")
    }
}
