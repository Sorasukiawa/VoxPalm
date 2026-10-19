import AppKit
import SwiftUI
import VoxPalmEngine

/// 编辑小窗里的一个动作按钮。AI 编程工具的几个常用动作单独列出来，不用自己找菜单；带「…」的要再填一样东西。
enum ActionChoice: String, CaseIterable, Identifiable {
    case pushToTalk, toggleDictation
    case openClaude, openCodex, previousChat, nextChat, newClaudeSession, newCodexChat, sendReturn
    case shortcut, text, mediaKey, openApp, none

    var id: String { rawValue }

    /// 按钮上的字（设计稿第 06 节）
    var title: String {
        switch self {
        case .pushToTalk: return "按住说话"
        case .toggleDictation: return "开始 / 结束说话"
        case .openClaude: return "打开 Claude Code"
        case .openCodex: return "打开 Codex"
        case .previousChat: return "上一个对话"
        case .nextChat: return "下一个对话"
        case .newClaudeSession: return "Claude：新会话"
        case .newCodexChat: return "Codex：新对话"
        case .sendReturn: return "发送（回车）"
        case .shortcut: return "快捷键…"
        case .text: return "输入一段文字…"
        case .mediaKey: return "媒体键…"
        case .openApp: return "打开 App…"
        case .none: return "不做事"
        }
    }

    var help: String? {
        switch self {
        case .pushToTalk: return "按住开始说话，松手出字。按下的瞬间就开始录音，不会吞掉第一个字。"
        case .toggleDictation: return "按一下开始说话，再按一下结束出字。"
        case .openClaude: return "切到 Claude 并打开 Code 页。"
        case .openCodex: return "切到 Codex（ChatGPT App）。"
        case .previousChat, .nextChat: return "前台是 Claude 或 Codex 时，切到侧边栏里的上一个 / 下一个对话；别的 App 在前台时不做事。"
        case .newClaudeSession: return "切到 Claude，开一个新会话。"
        case .newCodexChat: return "切到 Codex，开一个新对话。"
        case .sendReturn: return "按回车发送。只在光标停在有字的输入框里时才按，免得误发。"
        case .shortcut: return "模拟按一个快捷键，点了以后按一下要的组合。"
        case .text: return "在光标处输入一段固定的文字。"
        case .mediaKey: return "模拟播放 / 暂停、音量这些媒体键。"
        case .openApp: return "打开或切到一个 App。"
        case .none: return nil
        }
    }

    static let groups: [(String, [ActionChoice])] = [
        ("说话", [.pushToTalk, .toggleDictation]),
        ("AI 编程", [.openClaude, .openCodex, .previousChat, .nextChat, .newClaudeSession, .newCodexChat, .sendReturn]),
        ("通用", [.shortcut, .text, .mediaKey, .openApp]),
    ]

    var isVoice: Bool { self == .pushToTalk || self == .toggleDictation }

    /// 要再填一样东西（快捷键、文字、媒体键、App）才设得上
    var needsInput: Bool { [.shortcut, .text, .mediaKey, .openApp].contains(self) }

    /// 做完能接着说话：语音动作本身就是说话，「发送」完再说话没有意义
    var canTalkAfter: Bool { !isVoice && self != .sendReturn && self != .none }

    /// 不用再填东西的动作，点一下就能设上
    var fixedAction: Action? {
        switch self {
        case .pushToTalk: return .pushToTalk
        case .toggleDictation: return .toggleDictation
        case .openClaude: return .menuCommand(AIToolProfile.claude.open)
        case .openCodex: return .menuCommand(AIToolProfile.codex.open)
        case .previousChat: return .switchChat(.previous)
        case .nextChat: return .switchChat(.next)
        case .newClaudeSession: return .menuCommand(AIToolProfile.claude.newChat)
        case .newCodexChat: return .menuCommand(AIToolProfile.codex.newChat)
        case .sendReturn: return .sendReturn
        case .none: return Action.none
        case .shortcut, .text, .mediaKey, .openApp: return nil
        }
    }

    init(_ action: Action) {
        switch action {
        case .pushToTalk: self = .pushToTalk
        case .toggleDictation: self = .toggleDictation
        case let .menuCommand(command):
            switch command {
            case AIToolProfile.claude.open: self = .openClaude
            case AIToolProfile.codex.open: self = .openCodex
            case AIToolProfile.claude.newChat: self = .newClaudeSession
            case AIToolProfile.codex.newChat: self = .newCodexChat
            default: self = .none
            }
        case let .switchChat(direction): self = direction == .previous ? .previousChat : .nextChat
        case .sendReturn: self = .sendReturn
        case .shortcut: self = .shortcut
        case .text: self = .text
        case .mediaKey: self = .mediaKey
        case .openApp: self = .openApp
        case .none: self = .none
        }
    }
}

/// 点图上的键（或表里的格子）弹出的编辑小窗（设计稿第 06 节）：上面选单击 / 双击 / 长按，下面是按「说话 / AI 编程 / 通用」
/// 分组的动作按钮，点一下就设上，图上的标注跟着变。快捷键、文字这些要再填东西的，在按钮下面展开输入，填好才设上。
struct SpotEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let button: ButtonID
    let name: String
    let reportsRelease: Bool
    @State private var gesture: GestureKind
    /// 点了要再填东西的动作、还没填好：先亮着这个按钮，填好才真的设上
    @State private var pending: ActionChoice?
    @State private var text = ""
    @FocusState private var textFocused: Bool

    init(button: ButtonID, name: String, reportsRelease: Bool, initial: GestureKind? = nil) {
        self.button = button
        self.name = name
        self.reportsRelease = reportsRelease
        let fallback: GestureKind = reportsRelease ? .long : .single
        _gesture = State(initialValue: initial.map { reportsRelease || $0 != .long ? $0 : fallback } ?? fallback)
    }

    private var binding: KeyBinding? { model.binding(for: button, gesture: gesture) }

    /// 这一格现在设的动作（没设、或者是旧版的「不做事」都算空）
    private var current: ActionChoice? {
        guard let binding, binding.action != .none else { return nil }
        return ActionChoice(binding.action)
    }

    private var selected: ActionChoice? { pending ?? current }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                KeyChip(name: name)
                Spacer()
                Button("完成") { dismiss() }
                    .prominentButton()
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            GestureTabs(selection: $gesture, reportsRelease: reportsRelease)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(ActionChoice.groups, id: \.0) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.0).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.tertiary)
                        FlowLayout(spacing: 5) {
                            ForEach(group.1) { choice in
                                Button(choice.title) { pick(choice) }
                                    .buttonStyle(ActionChipStyle(selected: selected == choice))
                                    .disabled(choice == .pushToTalk && gesture != .long)
                                    .help(help(for: choice))
                            }
                        }
                    }
                }
            }
            if let selected, selected.needsInput {
                input(for: selected)
                    .transition(.opacity.combined(with: .offset(y: -4)))
            }
            options
            if current != nil {
                Button { clear() } label: {
                    Label("清除这一格", systemImage: "trash").font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .transition(.opacity)
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        // 弹出框是单独的窗口，不继承设置窗口的珊瑚色
        .tint(Brand.coralBottom)
        .animation(Motion.pick(Motion.bounce), value: current)
        .onAppear(perform: loadText)
        .onChange(of: gesture) { _, _ in
            pending = nil
            loadText()
        }
    }

    private func help(for choice: ActionChoice) -> String {
        if choice == .pushToTalk && gesture != .long {
            return reportsRelease ? "按住说话要设在长按上" : "这台设备读不到松开，用「开始 / 结束说话」"
        }
        return choice.help ?? ""
    }

    // MARK: - 选动作

    private func pick(_ choice: ActionChoice) {
        if let action = choice.fixedAction {
            // 再点一下已经选中的就清掉这一格（设计稿）
            if selected == choice { clear() } else { save(action) }
            return
        }
        // 要再填东西：已经是它就不动，否则先亮着等填好
        guard current != choice else {
            pending = nil
            return
        }
        text = ""
        withAnimation(Motion.pick(Motion.smooth)) { pending = choice }
    }

    private func save(_ action: Action, animated: Bool = true) {
        let new = Self.binding(action, button: button, name: name, gesture: gesture, replacing: binding)
        let apply = {
            pending = nil
            model.setBinding(new)
        }
        if animated { withAnimation(Motion.pick(Motion.bounce), apply) } else { apply() }
    }

    /// 换动作时尽量留住两个勾选：新动作也能用的就接着用。
    static func binding(_ action: Action, button: ButtonID, name: String, gesture: GestureKind, replacing old: KeyBinding?) -> KeyBinding {
        let choice = ActionChoice(action)
        let talkAfter = choice.canTalkAfter && old?.talkAfter == true
        let send = (choice.isVoice || choice.canTalkAfter) && old?.sendAfterTalk == true
        return KeyBinding(id: old?.id ?? UUID(), button: button, buttonLabel: name, gesture: gesture, action: action,
                          talkAfter: talkAfter ? true : nil, sendAfterTalk: send ? true : nil)
    }

    private func clear() {
        withAnimation(Motion.pick(Motion.bounce)) {
            pending = nil
            model.removeBinding(button: button, gesture: gesture)
        }
        text = ""
    }

    private func loadText() {
        if case let .text(value) = binding?.action { text = value } else { text = "" }
    }

    // MARK: - 要再填的东西

    @ViewBuilder
    private func input(for choice: ActionChoice) -> some View {
        Group {
            switch choice {
            case .shortcut:
                HStack(spacing: 8) {
                    Text("要模拟的快捷键").foregroundStyle(.secondary)
                    Spacer()
                    ShortcutRecorder(combo: Binding(get: {
                        if case let .shortcut(combo) = binding?.action { return combo }
                        return nil
                    }, set: { combo in
                        if let combo { save(.shortcut(combo)) }
                    }), startsRecording: current != .shortcut)
                }
            case .text:
                TextField("要输入的文字", text: Binding(get: { text }, set: { value in
                    text = value
                    // 边打边设上（设置文件晚半秒才写），标注跟着变
                    if !value.isEmpty { save(.text(value), animated: false) }
                }))
                .textFieldStyle(.roundedBorder)
                .focused($textFocused)
                .onSubmit { dismiss() }
                .onAppear { if current != .text { DispatchQueue.main.async { textFocused = true } } }
            case .mediaKey:
                FlowLayout(spacing: 5) {
                    ForEach(MediaKey.allCases, id: \.self) { key in
                        Button(key.title) { save(.mediaKey(key)) }
                            .buttonStyle(ActionChipStyle(selected: binding?.action == .mediaKey(key)))
                    }
                }
            case .openApp:
                HStack(spacing: 8) {
                    if case let .openApp(path) = binding?.action {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 18, height: 18)
                        Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension).lineLimit(1)
                    } else {
                        Text("还没选 App").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("选择 App…", action: chooseApp)
                        .secondaryButton()
                        .controlSize(.small)
                }
            default:
                EmptyView()
            }
        }
        .font(.system(size: 12))
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.045)))
    }

    /// 设好了的动作下面的两个勾选：AI 编程和通用动作做完能接着说话，说话的动作说完能自动发送。
    @ViewBuilder
    private var options: some View {
        if pending == nil, let current, let binding, current.isVoice || current.canTalkAfter {
            VStack(alignment: .leading, spacing: 6) {
                Divider().padding(.bottom, 2)
                if current.canTalkAfter {
                    Toggle("做完直接开始说话（再按一次这个键结束）", isOn: Binding(get: { binding.talkAfter == true }, set: { on in
                        update { $0.talkAfter = on ? true : nil }
                    }))
                }
                Toggle("说完自动按回车发送", isOn: Binding(get: { binding.sendAfterTalk == true }, set: { on in
                    update { $0.sendAfterTalk = on ? true : nil }
                }))
                .disabled(!binding.startsVoice)
                .help(binding.startsVoice ? "字贴进输入框后按回车；光标不在有字的输入框里时不按。" : "先勾上「做完直接开始说话」")
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
        }
    }

    private func update(_ change: (inout KeyBinding) -> Void) {
        guard var updated = binding else { return }
        change(&updated)
        withAnimation(Motion.pick(Motion.bounce)) { model.setBinding(updated) }
    }

    private func chooseApp() {
        // 选 App 的窗口是模态的，期间小窗可能被收起：先记下要改哪一格
        let model = model, button = button, name = name, gesture = gesture, old = binding
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        withAnimation(Motion.pick(Motion.bounce)) {
            pending = nil
            model.setBinding(Self.binding(.openApp(path: url.path), button: button, name: name, gesture: gesture, replacing: old))
        }
    }
}

/// 单击 / 双击 / 长按分段：选中的底色用弹簧滑过去。读不到松开的设备，长按灰着。
struct GestureTabs: View {
    @Binding var selection: GestureKind
    let reportsRelease: Bool
    @Namespace private var thumb

    var body: some View {
        HStack(spacing: 2) {
            ForEach(GestureKind.allCases, id: \.self) { gesture in
                let on = gesture == selection
                let unavailable = gesture == .long && !reportsRelease
                Button {
                    withAnimation(Motion.pick(Motion.bounce)) { selection = gesture }
                } label: {
                    HStack(spacing: 5) {
                        GestureGlyph(gesture: gesture, tint: on ? nil : .secondary)
                        Text(gesture.title)
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: 22)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.tabThumb)
                                .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                                .matchedGeometryEffect(id: "thumb", in: thumb)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(unavailable)
                .opacity(unavailable ? 0.4 : 1)
                .help(unavailable ? "这台设备读不到松开，做不了长按" : "")
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.07)))
    }
}

/// 动作按钮：选中的珊瑚色底加细边，按下时缩一点。
struct ActionChipStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        ZStack {
            // 先按粗体占好宽度，选中变粗时不会挤得换行
            configuration.label.font(.system(size: 12, weight: .semibold)).hidden()
            configuration.label.font(.system(size: 12, weight: selected ? .semibold : .regular))
        }
        .foregroundStyle(selected ? AnyShapeStyle(Brand.coralText) : AnyShapeStyle(.primary))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Brand.coralTop.opacity(0.16) : Color.primary.opacity(configuration.isPressed ? 0.1 : 0.045))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(selected ? Brand.coralTop.opacity(0.55) : Color.primary.opacity(0.1), lineWidth: selected ? 1 : 0.5)
        )
        .scaleEffect(configuration.isPressed && !Motion.reduceMotion ? 0.96 : 1)
        .animation(Motion.press, value: configuration.isPressed)
        .opacity(isEnabled ? 1 : 0.4)
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// 从左往右排，一行放不下就换行（动作按钮网格用）。
struct FlowLayout: Layout {
    var spacing: CGFloat = 5
    var lineSpacing: CGFloat = 5

    private struct Row {
        var items: [(index: Int, x: CGFloat, size: CGSize)] = []
        var y: CGFloat = 0
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews, width: proposal.width ?? .infinity)
        let height = rows.last.map { $0.y + $0.height } ?? 0
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for row in arrange(subviews, width: bounds.width) {
            for item in row.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: bounds.minY + row.y), proposal: ProposedViewSize(item.size))
            }
        }
    }

    private func arrange(_ subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for (index, subview) in subviews.enumerated() {
            let size = subview.sizeThatFits(.unspecified)
            let x = row.items.isEmpty ? 0 : row.width + spacing
            if !row.items.isEmpty, x + size.width > width {
                rows.append(row)
                row = Row(items: [(index, 0, size)], y: row.y + row.height + lineSpacing, width: size.width, height: size.height)
            } else {
                row.items.append((index, x, size))
                row.width = x + size.width
                row.height = max(row.height, size.height)
            }
        }
        if !row.items.isEmpty { rows.append(row) }
        return rows
    }
}

/// 点一下然后按快捷键，记下键码和修饰键。
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    /// 一出现就开始录（刚点了「快捷键…」）
    var startsRecording = false
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Text(recording ? "请按快捷键…" : combo?.display ?? "还没设置")
                .font(.system(size: 12.5, weight: .medium))
                .monospaced(combo != nil && !recording)
                .foregroundStyle(recording ? AnyShapeStyle(Brand.coralText) : combo == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(recording ? Brand.coralTop.opacity(0.14) : Color.primary.opacity(0.06)))
            Button(recording ? "取消" : combo == nil ? "录制" : "重录") { recording ? stop() : start() }
                .secondaryButton()
                .controlSize(.small)
        }
        .onAppear { if startsRecording { start() } }
        .onDisappear { stop() }
    }

    private func start() {
        guard monitor == nil else { return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            combo = KeyCombo(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue),
                             display: KeyNames.display(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum KeyNames {
    static func display(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (special[keyCode] ?? characters?.uppercased() ?? "#\(keyCode)")
    }

    static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
}
