import Foundation

/// 一台「控制设备」：真实的 HID 设备，或者「系统媒体键」这类不分设备的来源。
public struct ControlDevice: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let sourceID: String
    public let name: String
    public let detail: String
    /// 能不能读到「松开」：读不到的设备做不了长按和按住说话
    public let reportsRelease: Bool

    public init(id: String, sourceID: String, name: String, detail: String, reportsRelease: Bool) {
        self.id = id
        self.sourceID = sourceID
        self.name = name
        self.detail = detail
        self.reportsRelease = reportsRelease
    }
}

/// 设备上的一个键。用字符串表示，方便存进配置：`hid:0x0C:0xCD`、`media:16`、`key:36`、`remote:togglePlayPause`。
public struct ButtonID: Codable, Hashable, Sendable, RawRepresentable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static func hid(page: Int, usage: Int) -> ButtonID { ButtonID(String(format: "hid:0x%02X:0x%02X", page, usage)) }
    public static func media(_ code: Int) -> ButtonID { ButtonID("media:\(code)") }
    public static func key(_ code: Int) -> ButtonID { ButtonID("key:\(code)") }
    public static func remote(_ command: String) -> ButtonID { ButtonID("remote:\(command)") }
}

public struct ButtonEvent: Sendable {
    public enum Phase: String, Sendable {
        case down
        case up
        /// 一次性的触发，没有按下 / 松开之分（比如「正在播放」的播放暂停命令）
        case trigger
    }

    public let deviceID: String
    public let button: ButtonID
    public let label: String
    public let phase: Phase
    public let time: Double

    public init(deviceID: String, button: ButtonID, label: String, phase: Phase, time: Double) {
        self.deviceID = deviceID
        self.button = button
        self.label = label
        self.phase = phase
        self.time = time
    }
}
