import Foundation

/// 探针记下的一条事件。所有通道统一成这一种格式，方便按时间排在一起看。
public struct ProbeEvent: Codable, Sendable, Equatable {
    public enum Channel: String, Codable, Sendable {
        /// HID 设备上报的值（已按用途解析）
        case hid
        /// HID 原始输入报告（十六进制）
        case hidReport = "hid-report"
        /// 系统媒体键（NX_SYSDEFINED）
        case mediaKey = "media-key"
        /// 系统键盘事件（看不出来自哪台设备）
        case key
        /// 系统「正在播放」遥控命令（MPRemoteCommandCenter，蓝牙 AVRCP 走这里）
        case remoteCommand = "remote-command"
        /// CoreAudio：音量、静音、采样率、默认设备变化
        case audio
        /// 设备连上 / 断开
        case device
    }

    public enum Phase: String, Codable, Sendable {
        case down, up, trigger, `repeat`, value, change, added, removed
    }

    /// 相对探针启动的秒数
    public var t: Double
    public var channel: Channel
    public var device: String?
    /// 用来区分同名设备：HID 是「厂商:产品|名称|传输」，音频是 UID。导出时会遮掉蓝牙地址。
    public var deviceKey: String?
    public var control: String
    public var phase: Phase
    public var value: Double?
    public var raw: String?

    public init(t: Double, channel: Channel, device: String? = nil, deviceKey: String? = nil, control: String, phase: Phase, value: Double? = nil, raw: String? = nil) {
        self.t = t
        self.channel = channel
        self.device = device
        self.deviceKey = deviceKey
        self.control = control
        self.phase = phase
        self.value = value
        self.raw = raw
    }

    /// 是不是「有人按了键」的信号（用来判断一步测试什么时候结束）。原始报告和连续变化的坐标不算。
    public var isSignal: Bool {
        switch channel {
        case .hidReport: return false
        case .hid: return phase != .value
        default: return true
        }
    }

    public var channelTitle: String {
        switch channel {
        case .hid: return "HID"
        case .hidReport: return "HID 原始"
        case .mediaKey: return "媒体键"
        case .key: return "键盘"
        case .remoteCommand: return "正在播放"
        case .audio: return "音频"
        case .device: return "设备"
        }
    }

    public var phaseTitle: String {
        switch phase {
        case .down: return "按下"
        case .up: return "松开"
        case .trigger: return "触发"
        case .repeat: return "连发"
        case .value: return "值"
        case .change: return "变化"
        case .added: return "连上"
        case .removed: return "断开"
        }
    }

    public var line: String {
        var text = String(format: "+%7.3fs  ", t) + channelTitle
        if let device { text += "  \(device)" }
        text += "  \(control)  \(phaseTitle)"
        if let value { text += " \(value.formatted(.number.precision(.fractionLength(0...3))))" }
        if let raw { text += "  [\(raw)]" }
        return text
    }
}
