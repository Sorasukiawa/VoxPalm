import CoreGraphics
import Foundation
import VoxPalmEngine

/// 外部输入法（豆包、微信输入法、Typeless、系统听写……）的语音键。
public struct InputMethodKey: Codable, Hashable, Sendable {
    public enum Key: String, Codable, CaseIterable, Sendable {
        case fn
        case rightOption
        case rightCommand
        case rightControl
        case rightShift
        case custom

        public var title: String {
            switch self {
            case .fn: return "Fn（🌐）"
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
