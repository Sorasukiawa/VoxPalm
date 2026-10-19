import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxPalmEngine

/// 按键页：上面是设备示意图，点一个键，下面设它的单击、双击、长按。
struct KeysTab: View {
    @Environment(AppModel.self) private var model
    @State private var selectedSpot: String?
    @State private var editing: EditTarget?
    @State private var confirmPreset = false

    struct EditTarget: Identifiable {
        let button: ButtonID
        let name: String
        let gesture: GestureKind
        var id: String { "\(button.rawValue)|\(gesture.rawValue)" }
    }

    var body: some View {
        Form {
            if let device = model.activeDevice {
                let resolved = model.diagram(for: device)
                Section {
                    if !resolved.isFixed {
                        Picker("外形", selection: Binding(
                            get: { resolved.diagram.id },
                            set: { model.setDiagram($0, for: device.id) }
                        )) {
                            ForEach(DeviceDiagram.choices) { Text($0.title).tag($0.id) }
                            if resolved.diagram.id == DeviceDiagram.mediaKeys.id { Text(DeviceDiagram.mediaKeys.title).tag(DeviceDiagram.mediaKeys.id) }
                        }
                    }
                    DeviceDiagramView(
                        diagram: resolved.diagram,
                        callouts: DiagramCallout.make(diagram: resolved.diagram, buttons: resolved.buttons, keyMap: model.config.keyMap,
                                                      reportsRelease: resolved.reportsRelease, learning: model.learningSpot),
                        pressed: model.pressedButtons,
                        buttons: resolved.buttons,
                        selected: selectedSpot,
                        onSelect: { selectedSpot = $0 }
                    )
                    HStack {
                        if resolved.diagram.id == "generic" {
                            Button(model.learningSpot == "+" ? "请按设备上的键……" : "加一个键") { model.startLearning(spot: "+") }
                                .disabled(model.learningSpot != nil)
                        }
                        if model.learningSpot != nil {
                            Button("取消学键") { model.cancelLearning() }
                        }
                        Spacer()
                        if AIPreset.bindings(for: resolved).isEmpty == false {
                            Button("套用「AI 编程」预设…") { confirmPreset = true }
                        }
                    }
                } header: {
                    Text(device.name)
                } footer: {
                    Text((resolved.diagram.note.map { $0 + "。" } ?? "") + (resolved.isFixed
                         ? "照产品图画的示意图。按设备上的键，图上对应的键会亮。"
                         : resolved.diagram.id == DeviceDiagram.mediaKeys.id
                         ? "键盘最上面一排的媒体键（也包括蓝牙耳机、遥控器发出的播放、音量键）。按键时图上会亮。"
                         : "照产品图画的示意图。先点图上的键、再按一下设备上的同一个键，把它们对上；按键时图上会亮。"))
                }
                .alert("套用「AI 编程」预设？", isPresented: $confirmPreset) {
                    Button("套用") { applyPreset(resolved) }
                    Button("取消", role: .cancel) {}
                } message: {
                    Text(AIPreset.description(for: resolved))
                }

                if let spotID = selectedSpot, let spot = resolved.diagram.spots.first(where: { $0.id == spotID }) {
                    Section("「\(spot.name)」") {
                        spotEditor(spot, device: device, resolved: resolved)
                    }
                }

                let shown = Set(resolved.buttons.values)
                let others = model.config.keyMap.bindings.filter { !shown.contains($0.button) }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { binding in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(binding.buttonLabel) · \(binding.gesture.title)")
                                    Text(binding.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(role: .destructive) { model.removeBinding(binding.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } header: {
                        Text("图上没有的映射")
                    } footer: {
                        Text("以前学的键，或者还没在图上对上位置的键。")
                    }
                }
            } else {
                Section {
                    Text("先在「设备」里选一个控制设备。").foregroundStyle(.secondary)
                }
            }

            Section("手势判定") {
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
        .sheet(item: $editing) { target in
            ActionEditor(button: target.button, buttonName: target.name, gesture: target.gesture)
                .environment(model)
        }
        .onChange(of: model.activeDevice?.id) { _, _ in selectedSpot = nil }
    }

    @ViewBuilder
    private func spotEditor(_ spot: DeviceDiagram.Spot, device: ControlDevice, resolved: AppModel.ResolvedDiagram) -> some View {
        if model.learningSpot == spot.id {
            HStack {
                ProgressView().controlSize(.small)
                Text("请按一下「\(device.name)」上的「\(spot.name)」……")
                Spacer()
                Button("取消") { model.cancelLearning() }
            }
        } else if let button = resolved.buttons[spot.id] {
            ForEach(GestureKind.allCases, id: \.self) { gesture in
                let binding = model.binding(for: button, gesture: gesture)
                let disabled = gesture == .long && !resolved.reportsRelease
                HStack {
                    Text(gesture.title).frame(width: 40, alignment: .leading)
                    Text(disabled ? "这台设备读不到松开，没有长按" : binding?.summary ?? "没设置")
                        .foregroundStyle(binding == nil || disabled ? .tertiary : .primary)
                        .lineLimit(1)
                    Spacer()
                    Button(binding == nil ? "设置…" : "修改…") {
                        editing = EditTarget(button: button, name: spot.name, gesture: gesture)
                    }
                    .disabled(disabled)
                }
            }
            ForEach(spot.reserved, id: \.self) { note in
                Label("设备自己占用：\(note)，不要拿来映射", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
            if spot.button == nil {
                HStack {
                    Button("重新学这个键") { model.startLearning(spot: spot.id) }
                    Button("解除对应") { model.forgetSpot(spot.id, deviceID: device.id) }
                }
                .buttonStyle(.link)
            }
        } else {
            Text("这个位置还没对上设备上的键。").foregroundStyle(.secondary)
            Button("学这个键") { model.startLearning(spot: spot.id) }
        }
    }

    private func applyPreset(_ resolved: AppModel.ResolvedDiagram) {
        let bindings = AIPreset.bindings(for: resolved)
        for binding in bindings { model.setBinding(binding) }
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
