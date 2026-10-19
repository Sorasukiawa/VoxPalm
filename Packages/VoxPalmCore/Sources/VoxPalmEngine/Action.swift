import Foundation

/// 一个快捷键：虚拟键码 + 修饰键（CGEventFlags 的原始值）。
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    /// 给人看的写法，例如「⌘⇧4」
    public var display: String

    public init(keyCode: UInt16, modifiers: UInt64 = 0, display: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.display = display
    }

    public static let returnKey = KeyCombo(keyCode: 36, display: "↩")
    public static let escape = KeyCombo(keyCode: 53, display: "⎋")
    public static let space = KeyCombo(keyCode: 49, display: "空格")
}

public enum MediaKey: String, Codable, CaseIterable, Sendable {
    case playPause
    case next
    case previous
    case volumeUp
    case volumeDown
    case mute

    /// NX_KEYTYPE_* 键码（IOKit/hidsystem/ev_keymap.h）
    public var nxCode: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    public var title: String {
        switch self {
        case .playPause: return "播放 / 暂停"
        case .next: return "下一首"
        case .previous: return "上一首"
        case .volumeUp: return "音量 +"
        case .volumeDown: return "音量 −"
        case .mute: return "静音"
        }
    }
}

/// 按键触发的动作。免费版的全部动作都在这里；组合动作、录音剪辑动作包在 Pro 包里。
public enum Action: Codable, Hashable, Sendable {
    case none
    case shortcut(KeyCombo)
    case text(String)
    case mediaKey(MediaKey)
    case openApp(path: String)
    /// 按住说话：绑在长按上，按住开始、松手结束
    case pushToTalk
    /// 按一下开始说话，再按一下结束
    case toggleDictation

    public var title: String {
        switch self {
        case .none: return "不做事"
        case let .shortcut(combo): return "快捷键 \(combo.display)"
        case let .text(text): return "输入文字「\(text.count > 12 ? String(text.prefix(12)) + "…" : text)」"
        case let .mediaKey(key): return key.title
        case let .openApp(path): return "打开 \(((path as NSString).lastPathComponent as NSString).deletingPathExtension)"
        case .pushToTalk: return "按住说话"
        case .toggleDictation: return "按一下开始 / 结束说话"
        }
    }

    public var isVoice: Bool {
        switch self {
        case .pushToTalk, .toggleDictation: return true
        default: return false
        }
    }
}

public struct KeyBinding: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var button: ButtonID
    /// 学键时记下的名字，例如「Consumer · Play/Pause」
    public var buttonLabel: String
    public var gesture: GestureKind
    public var action: Action

    public init(id: UUID = UUID(), button: ButtonID, buttonLabel: String, gesture: GestureKind, action: Action) {
        self.id = id
        self.button = button
        self.buttonLabel = buttonLabel
        self.gesture = gesture
        self.action = action
    }
}

/// 一套键位方案。免费版只有一套全局方案。
public struct KeyMap: Codable, Hashable, Sendable {
    public var name: String
    public var bindings: [KeyBinding]

    public init(name: String = "默认", bindings: [KeyBinding] = []) {
        self.name = name
        self.bindings = bindings
    }

    public func action(for button: ButtonID, gesture: GestureKind) -> Action? {
        bindings.first { $0.button == button && $0.gesture == gesture }?.action
    }

    public func hasBinding(_ button: ButtonID, _ gesture: GestureKind) -> Bool {
        guard let action = action(for: button, gesture: gesture) else { return false }
        return action != .none
    }

    public func isMapped(_ button: ButtonID) -> Bool {
        GestureKind.allCases.contains { hasBinding(button, $0) }
    }

    /// 同一个键、同一个手势只留一条。
    public mutating func set(_ binding: KeyBinding) {
        bindings.removeAll { $0.button == binding.button && $0.gesture == binding.gesture && $0.id != binding.id }
        if let index = bindings.firstIndex(where: { $0.id == binding.id }) {
            bindings[index] = binding
        } else {
            bindings.append(binding)
        }
    }
}
