import AppKit
import ApplicationServices
import CoreGraphics
import VoxPalmDevices

/// 模拟按键。往系统发事件要「辅助功能」权限，没有的话系统会直接丢掉。
public enum KeyPoster {
    public static var canPost: Bool { AXIsProcessTrusted() }

    /// 弹出系统的辅助功能授权提示（已经授权就什么都不做）。
    public static func promptForAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    public static let marker = SystemEventMonitor.syntheticMarker

    public static func post(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        let flags = CGEventFlags(rawValue: combo.modifiers)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down) else { continue }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
            event.post(tap: .cghidEventTap)
        }
    }

    public static func postMediaKey(_ key: MediaKey) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xA00 : 0xB00)
            let data1 = (key.nxCode << 16) | ((down ? 0xA : 0xB) << 8)
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            )
            guard let cgEvent = event?.cgEvent else { continue }
            cgEvent.setIntegerValueField(.eventSourceUserData, value: marker)
            cgEvent.post(tap: .cghidEventTap)
        }
    }

    /// 修饰键（Fn、右 Option 等）单独按下或松开。用来按住外部输入法的语音键。
    public static func postModifier(keyCode: UInt16, flag: CGEventFlags, down: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? flag : []
        event.setIntegerValueField(.eventSourceUserData, value: marker)
        event.post(tap: .cghidEventTap)
    }
}
