import Foundation

/// HID 用途表（USB-IF「HID Usage Tables」公开规范）里常见用途的名字，报告和界面显示用。
public enum HIDUsageNames {
    public static func page(_ page: Int) -> String {
        switch page {
        case 0x01: return "Generic Desktop"
        case 0x06: return "Generic Device"
        case 0x07: return "Keyboard"
        case 0x08: return "LED"
        case 0x09: return "Button"
        case 0x0B: return "Telephony"
        case 0x0C: return "Consumer"
        case 0x0D: return "Digitizer"
        case 0x0F: return "Physical Interface"
        case 0x20: return "Sensor"
        case 0x84: return "Power"
        case 0x85: return "Battery"
        case 0xFF00...0xFFFF: return String(format: "Vendor 0x%04X", page)
        default: return String(format: "Page 0x%02X", page)
        }
    }

    public static func usage(page: Int, usage: Int) -> String {
        switch page {
        case 0x01: return genericDesktop[usage] ?? hex(usage)
        case 0x07: return keyboard(usage)
        case 0x09: return "Button \(usage)"
        case 0x0B: return telephony[usage] ?? hex(usage)
        case 0x0C: return consumer[usage] ?? hex(usage)
        default: return hex(usage)
        }
    }

    /// 例：「Consumer · Play/Pause」
    public static func describe(page: Int, usage: Int) -> String {
        "\(self.page(page)) · \(self.usage(page: page, usage: usage))"
    }

    /// 设备整体是什么（按主用途判断），中文。
    public static func deviceKind(page: Int, usage: Int) -> String {
        switch (page, usage) {
        case (0x01, 0x02): return "鼠标"
        case (0x01, 0x01): return "指针"
        case (0x01, 0x06): return "键盘"
        case (0x01, 0x07): return "小键盘"
        case (0x01, 0x04), (0x01, 0x05): return "手柄"
        case (0x01, 0x80): return "系统控制键"
        case (0x0C, 0x01): return "媒体键（Consumer Control）"
        case (0x0B, _): return "电话控制键"
        case (0x0D, _): return "触控/手写"
        case (0xFF00...0xFFFF, _): return "厂商自定义"
        default: return describe(page: page, usage: usage)
        }
    }

    private static func hex(_ value: Int) -> String { String(format: "0x%02X", value) }

    private static let genericDesktop: [Int: String] = [
        0x01: "Pointer", 0x02: "Mouse", 0x04: "Joystick", 0x05: "Game Pad", 0x06: "Keyboard", 0x07: "Keypad",
        0x30: "X", 0x31: "Y", 0x32: "Z", 0x38: "Wheel", 0x39: "Hat Switch",
        0x80: "System Control", 0x81: "System Power Down", 0x82: "System Sleep", 0x83: "System Wake Up",
        0x84: "System Context Menu", 0x85: "System Main Menu", 0x86: "System App Menu",
        0x90: "D-pad Up", 0x91: "D-pad Down", 0x92: "D-pad Right", 0x93: "D-pad Left",
    ]

    private static let telephony: [Int: String] = [
        0x01: "Phone", 0x20: "Hook Switch", 0x21: "Flash", 0x24: "Redial", 0x26: "Drop", 0x2F: "Phone Mute",
    ]

    private static let consumer: [Int: String] = [
        0x01: "Consumer Control", 0x04: "Microphone", 0x30: "Power", 0x32: "Sleep",
        0x40: "Menu", 0x41: "Menu Pick", 0x42: "Menu Up", 0x43: "Menu Down", 0x44: "Menu Left", 0x45: "Menu Right",
        0x46: "Menu Escape", 0x60: "Data On Screen", 0x6F: "Brightness Up", 0x70: "Brightness Down",
        0x89: "Select TV", 0x8D: "Program Guide", 0x9C: "Channel Up", 0x9D: "Channel Down",
        0xB0: "Play", 0xB1: "Pause", 0xB2: "Record", 0xB3: "Fast Forward", 0xB4: "Rewind",
        0xB5: "Next Track", 0xB6: "Previous Track", 0xB7: "Stop", 0xB8: "Eject",
        0xCD: "Play/Pause", 0xCF: "Voice Command", 0xE2: "Mute", 0xE9: "Volume Up", 0xEA: "Volume Down",
        0x221: "AC Search", 0x223: "AC Home", 0x224: "AC Back", 0x225: "AC Forward", 0x22A: "AC Bookmarks",
    ]

    private static func keyboard(_ usage: Int) -> String {
        switch usage {
        case 0x04...0x1D: return String(UnicodeScalar(UInt8(0x61 + usage - 0x04)))
        case 0x1E...0x26: return String(usage - 0x1D)
        case 0x27: return "0"
        case 0x3A...0x45: return "F\(usage - 0x39)"
        default:
            let names: [Int: String] = [
                0x28: "Return", 0x29: "Escape", 0x2A: "Backspace", 0x2B: "Tab", 0x2C: "Space",
                0x4A: "Home", 0x4B: "Page Up", 0x4C: "Delete Forward", 0x4D: "End", 0x4E: "Page Down",
                0x4F: "Right Arrow", 0x50: "Left Arrow", 0x51: "Down Arrow", 0x52: "Up Arrow",
                0x65: "Application", 0x66: "Power", 0x7F: "Mute", 0x80: "Volume Up", 0x81: "Volume Down",
                0xE0: "Left Control", 0xE1: "Left Shift", 0xE2: "Left Option", 0xE3: "Left Command",
                0xE4: "Right Control", 0xE5: "Right Shift", 0xE6: "Right Option", 0xE7: "Right Command",
            ]
            return names[usage] ?? hex(usage)
        }
    }
}

/// 系统媒体键（NX_SYSDEFINED 事件里的键码，公开头文件 IOKit/hidsystem/ev_keymap.h）。
public enum MediaKeyNames {
    public static func name(_ code: Int) -> String {
        let names: [Int: String] = [
            0: "Volume Up", 1: "Volume Down", 2: "Brightness Up", 3: "Brightness Down", 4: "Caps Lock",
            5: "Help", 6: "Power", 7: "Mute", 8: "Up Arrow", 9: "Down Arrow", 10: "Num Lock",
            11: "Contrast Up", 12: "Contrast Down", 13: "Launch Panel", 14: "Eject", 15: "Video Mirror",
            16: "Play/Pause", 17: "Next", 18: "Previous", 19: "Fast Forward", 20: "Rewind",
            21: "Illumination Up", 22: "Illumination Down", 23: "Illumination Toggle",
        ]
        return names[code] ?? "Media Key \(code)"
    }
}
