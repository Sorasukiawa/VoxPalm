import Carbon
import CoreGraphics
import Foundation
import VoxPalmEngine

/// 外部输入法（豆包、微信输入法、Typeless、系统听写……）的语音键。
public struct InputMethodKey: Codable, Hashable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case fn
        /// 输入法里把语音键录成左 Option 时只认左边（2026-10-21 微信输入法实测，右 Option 叫不起）
        case leftOption
        case rightOption
        case rightCommand
        case rightControl
        case rightShift
        case custom

        public var title: String {
            switch self {
            case .fn: return "Fn（🌐）"
            case .leftOption: return "左 Option"
            case .rightOption: return "右 Option"
            case .rightCommand: return "右 Command"
            case .rightControl: return "右 Control"
            case .rightShift: return "右 Shift"
            case .custom: return "自定义快捷键"
            }
        }

        /// 虚拟键码，以及按下时的修饰键标志（含区分左右的设备位，有的输入法靠它分辨右侧键）
        var modifier: (keyCode: UInt16, flags: UInt64)? {
            switch self {
            case .fn: return (63, CGEventFlags.maskSecondaryFn.rawValue)
            case .leftOption: return (58, CGEventFlags.maskAlternate.rawValue | 0x20)
            case .rightOption: return (61, CGEventFlags.maskAlternate.rawValue | 0x40)
            case .rightCommand: return (54, CGEventFlags.maskCommand.rawValue | 0x10)
            case .rightControl: return (62, CGEventFlags.maskControl.rawValue | 0x2000)
            case .rightShift: return (60, CGEventFlags.maskShift.rawValue | 0x04)
            case .custom: return nil
            }
        }
    }

    public enum Style: String, Codable, CaseIterable, Sendable {
        /// 说话期间一直按住语音键
        case hold
        /// 开始时按一下，结束时再按一下
        case tap
        /// 开始时连按两下（系统听写的默认方式），结束时按一下
        case doubleTap

        public var title: String {
            switch self {
            case .hold: return "按住"
            case .tap: return "按一下开始、再按一下结束"
            case .doubleTap: return "连按两下开始、按一下结束"
            }
        }
    }

    public var key: Key
    public var style: Style
    public var custom: KeyCombo?

    public init(key: Key = .fn, style: Style = .hold, custom: KeyCombo? = nil) {
        self.key = key
        self.style = style
        self.custom = custom
    }
}

/// 模拟外部输入法的语音键。需要辅助功能权限。
public enum InputMethodBridge {
    public static func begin(_ key: InputMethodKey) {
        switch key.style {
        case .hold: press(key, down: true)
        case .tap: tap(key)
        case .doubleTap:
            tap(key)
            usleep(80_000)
            tap(key)
        }
    }

    public static func end(_ key: InputMethodKey) {
        switch key.style {
        case .hold: press(key, down: false)
        case .tap, .doubleTap: tap(key)
        }
    }

    private static func tap(_ key: InputMethodKey) {
        if key.key == .custom, let combo = key.custom {
            KeyPoster.post(combo)
            return
        }
        press(key, down: true)
        usleep(40_000)
        press(key, down: false)
    }

    private static func press(_ key: InputMethodKey, down: Bool) {
        if let modifier = key.key.modifier {
            KeyPoster.postModifier(keyCode: modifier.keyCode, flag: CGEventFlags(rawValue: modifier.flags), down: down)
        } else if down, let combo = key.custom {
            // 自定义快捷键没法「按住」，按下时按一次。
            KeyPoster.post(combo)
        }
    }
}

/// 系统里的输入法收音跟不跟系统默认输入走。外部输入法模式靠说话时临时切系统默认输入来换麦，不跟着走的输入法换不了。
public enum InputMethodMic {
    /// 实测不跟着切麦的输入法：输入法 ID 前缀 → 名字。
    /// 微信输入法 3.0：说话时系统默认输入已经切到别的麦，它照样录 Mac 自带麦（2026-10-21 实测）
    static let ignoringDefaultInput = ["com.tencent.inputmethod.wetype": "微信输入法"]

    /// 系统启用的输入法变了时发的通知（分布式通知）
    public static let enabledChangedNotification = Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String)

    /// 系统启用的输入法里有不跟着切麦的，返回它的名字。
    /// 看「启用了」而不是「当前选中」：微信输入法的语音快捷键是全局的，当前输入法是 ABC 时照样响应（2026-10-21 实测）
    public static func enabledIgnoringDefaultInput() -> String? {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else { return nil }
        for source in sources {
            guard let pointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            if let name = name(ignoringDefaultInput: Unmanaged<CFString>.fromOpaque(pointer).takeUnretainedValue() as String) { return name }
        }
        return nil
    }

    static func name(ignoringDefaultInput sourceID: String) -> String? {
        ignoringDefaultInput.first { sourceID.hasPrefix($0.key) }?.value
    }
}
