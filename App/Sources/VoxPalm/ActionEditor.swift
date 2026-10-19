import AppKit
import SwiftUI
import VoxPalmEngine

/// 动作选择器里的一项。AI 编程工具的几个常用动作单独列出来，不用自己找菜单。
enum ActionChoice: String, CaseIterable, Identifiable {
    case pushToTalk, toggleDictation
    case openClaude, openCodex, previousChat, nextChat, newClaudeSession, newCodexChat, sendReturn
    case shortcut, text, mediaKey, openApp, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pushToTalk: return "按住说话"
        case .toggleDictation: return "按一下开始 / 结束说话"
        case .openClaude: return "打开 Claude Code"
        case .openCodex: return "打开 Codex"
        case .previousChat: return "上一个对话"
        case .nextChat: return "下一个对话"
        case .newClaudeSession: return "Claude：新会话"
        case .newCodexChat: return "Codex：新对话"
        case .sendReturn: return "发送（回车）"
        case .shortcut: return "快捷键"
        case .text: return "输入一段文字"
        case .mediaKey: return "媒体键"
        case .openApp: return "打开 App"
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
        case .sendReturn: return "按回车发送。只在光标停在有字的输入框里时才按，免得误发。"
        default: return nil
        }
    }

    static let groups: [(String, [ActionChoice])] = [
        ("说话", [.pushToTalk, .toggleDictation]),
        ("AI 编程", [.openClaude, .openCodex, .previousChat, .nextChat, .newClaudeSession, .newCodexChat, .sendReturn]),
        ("通用", [.shortcut, .text, .mediaKey, .openApp, .none]),
    ]

    var isVoice: Bool { self == .pushToTalk || self == .toggleDictation }

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

/// 给某个键的某个手势选动作。
struct ActionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let button: ButtonID
    let buttonName: String
    let gesture: GestureKind

    @State private var choice: ActionChoice = .toggleDictation
    @State private var combo: KeyCombo?
    @State private var text = ""
    @State private var media: MediaKey = .playPause
    @State private var appPath: String?
    @State private var talkAfter = false
    @State private var sendAfterTalk = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(buttonName) · \(gesture.title)").font(.headline)
            Picker("动作", selection: $choice) {
                ForEach(ActionChoice.groups, id: \.0) { group in
                    Section(group.0) {
                        ForEach(group.1.filter { $0 != .pushToTalk || gesture == .long }) { Text($0.title).tag($0) }
                    }
                }
            }
            if let help = choice.help {
                Text(help).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            switch choice {
            case .shortcut:
                ShortcutRecorder(combo: $combo)
            case .text:
                TextField("要输入的文字", text: $text)
            case .mediaKey:
                Picker("媒体键", selection: $media) {
                    ForEach(MediaKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            case .openApp:
                HStack {
                    Text(appPath.map { ($0 as NSString).lastPathComponent } ?? "还没选")
                    Button("选择 App…") { chooseApp() }
                }
            default:
                EmptyView()
            }

            if !choice.isVoice && choice != .none && choice != .sendReturn {
                Toggle("做完直接开始说话（再按一次这个键结束）", isOn: $talkAfter)
            }
            if choice.isVoice || talkAfter {
                Toggle("说完自动按回车发送", isOn: $sendAfterTalk)
                if sendAfterTalk {
                    Text("字贴进输入框后按回车；光标不在有字的输入框里时不按。").font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack {
                if model.binding(for: button, gesture: gesture) != nil {
                    Button("清除", role: .destructive) {
                        model.removeBinding(button: button, gesture: gesture)
                        dismiss()
                    }
                }
                Spacer()
                Button("取消") { dismiss() }
                Button("保存") {
                    guard let action else { return }
                    let existing = model.binding(for: button, gesture: gesture)
                    model.setBinding(KeyBinding(
                        id: existing?.id ?? UUID(), button: button, buttonLabel: buttonName, gesture: gesture, action: action,
                        talkAfter: !choice.isVoice && talkAfter ? true : nil,
                        sendAfterTalk: (choice.isVoice || talkAfter) && sendAfterTalk ? true : nil
                    ))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action == nil)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear(perform: load)
    }

    private var action: Action? {
        switch choice {
        case .pushToTalk: return .pushToTalk
        case .toggleDictation: return .toggleDictation
        case .openClaude: return .menuCommand(AIToolProfile.claude.open)
        case .openCodex: return .menuCommand(AIToolProfile.codex.open)
        case .previousChat: return .switchChat(.previous)
        case .nextChat: return .switchChat(.next)
        case .newClaudeSession: return .menuCommand(AIToolProfile.claude.newChat)
        case .newCodexChat: return .menuCommand(AIToolProfile.codex.newChat)
        case .sendReturn: return .sendReturn
        case .shortcut: return combo.map(Action.shortcut)
        case .text: return text.isEmpty ? nil : .text(text)
        case .mediaKey: return .mediaKey(media)
        case .openApp: return appPath.map { .openApp(path: $0) }
        case .none: return Action.none
        }
    }

    private func load() {
        guard let binding = model.binding(for: button, gesture: gesture) else {
            choice = gesture == .long ? .pushToTalk : .toggleDictation
            return
        }
        choice = ActionChoice(binding.action)
        talkAfter = binding.talkAfter == true
        sendAfterTalk = binding.sendAfterTalk == true
        switch binding.action {
        case let .shortcut(value): combo = value
        case let .text(value): text = value
        case let .mediaKey(value): media = value
        case let .openApp(path): appPath = path
        default: break
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appPath = url.path
    }
}

/// 点一下然后按快捷键，记下键码和修饰键。
struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(combo?.display ?? "还没设置").monospaced()
            Button(recording ? "请按快捷键…" : "录制快捷键") { recording ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
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
