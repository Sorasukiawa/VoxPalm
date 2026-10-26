import Foundation

/// 只解释公开的按键输入布局。USB 与蓝牙基础/增强报告的偏移不同；不解析音频、固件或传感器。
public enum DualSenseInput {
    public static let buttonNames: [(String, String)] = [
        ("square", "□ 方块"), ("cross", "× 叉键"), ("circle", "○ 圆圈"), ("triangle", "△ 三角"),
        ("l1", "L1"), ("r1", "R1"), ("l2", "L2"), ("r2", "R2"),
        ("create", "创建键"), ("options", "选项键"), ("l3", "L3（左摇杆按下）"), ("r3", "R3（右摇杆按下）"),
        ("ps", "PS 键"), ("touchpad", "触摸板按下"), ("mute", "麦克风静音键"),
        ("up", "方向上"), ("right", "方向右"), ("down", "方向下"), ("left", "方向左"),
        ("fnLeft", "左 Fn"), ("fnRight", "右 Fn"), ("backLeft", "左背键"), ("backRight", "右背键")
    ]

    public static func button(_ name: String) -> ButtonID { ButtonID("gamepad:\(name)") }
    public static func label(_ button: ButtonID) -> String {
        buttonNames.first { Self.button($0.0) == button }?.1 ?? button.rawValue
    }

    /// 返回当前按住的键；未知、截断或损坏报告返回 nil，不能把坏包当作全部松开。
    public static func pressed(reportID: Int, bytes: [UInt8], edge: Bool) -> Set<ButtonID>? {
        guard bytes.first == UInt8(exactly: reportID) else { return nil }
        let offset: Int
        let complete: Bool
        switch (reportID, bytes.count) {
        case (0x01, 64): offset = 8; complete = true
        case (0x01, 10): offset = 5; complete = false
        case (0x31, 78):
            // 音频与按键共用 0x31 编号；音频内容不能被当成按键，也不能伪造全部松开。
            guard bytes[1] & 0x02 == 0, validBluetoothChecksum(bytes) else { return nil }
            offset = 9; complete = true
        default: return nil
        }
        var result = Set<ButtonID>()
        let flags = UInt32(bytes[offset] >> 4) | (UInt32(bytes[offset + 1]) << 4)
            | (UInt32(bytes[offset + 2] & (complete ? 0x07 : 0x03)) << 12)
        for (index, entry) in buttonNames.prefix(complete ? 15 : 14).enumerated() where flags & (1 << index) != 0 {
            result.insert(button(entry.0))
        }
        let direction = Int(bytes[offset] & 0x0F)
        let directions = ["up", "right", "down", "left"]
        // 八方向帽开关：对角线同时按住相邻两个方向；8 是中立位置。
        if direction < 8 {
            result.insert(button(directions[((direction + 1) / 2) % 4]))
            if direction % 2 == 1 { result.insert(button(directions[direction / 2])) }
        }
        if edge && complete {
            for (index, name) in ["fnLeft", "fnRight", "backLeft", "backRight"].enumerated()
                where bytes[offset + 2] & (1 << (index + 4)) != 0 {
                result.insert(button(name))
            }
        }
        return result
    }

    private static func validBluetoothChecksum(_ bytes: [UInt8]) -> Bool {
        // 蓝牙 HID 输入的 CRC32 额外包含 0xA1 前缀，末尾四字节是小端校验值。
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in [UInt8(0xA1)] + bytes.dropLast(4) {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 0 ? crc >> 1 : (crc >> 1) ^ 0xEDB8_8320 }
        }
        let expected = bytes.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return ~crc == expected
    }
}

/// 将完整状态变成边沿事件，重复报告不会重复触发；设备之间各自保留状态。
struct HIDButtonState {
    private var held: [String: Set<ButtonID>] = [:]

    mutating func update(_ buttons: Set<ButtonID>, deviceID: String, time: Double,
                         label: (ButtonID) -> String) -> [ButtonEvent] {
        let old = held[deviceID] ?? []
        held[deviceID] = buttons
        return [(old.subtracting(buttons), ButtonEvent.Phase.up), (buttons.subtracting(old), .down)].flatMap { keys, phase in
            keys.sorted { $0.rawValue < $1.rawValue }.map {
                ButtonEvent(deviceID: deviceID, button: $0, label: label($0), phase: phase, time: time)
            }
        }
    }

    mutating func update(_ button: ButtonID, down: Bool, deviceID: String, time: Double, label: String) -> [ButtonEvent] {
        var buttons = held[deviceID] ?? []
        if down { buttons.insert(button) } else { buttons.remove(button) }
        return update(buttons, deviceID: deviceID, time: time, label: { _ in label })
    }

    mutating func cancel(_ deviceID: String) { held.removeValue(forKey: deviceID) }
}
