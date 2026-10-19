import Foundation

public enum Gesture: String, Codable, CaseIterable, Sendable {
    case single
    case double
    case long1
    case long3

    public var title: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .long1: return "长按 1 秒"
        case .long3: return "长按 3 秒"
        }
    }

    public var instruction: String {
        switch self {
        case .single: return "按一下就松开"
        case .double: return "快速连按两下"
        case .long1: return "按住，心里数 1 秒再松开"
        case .long3: return "按住，心里数 3 秒再松开"
        }
    }

    /// 期望的按住时长（秒）
    public var holdSeconds: Double? {
        switch self {
        case .long1: return 1
        case .long3: return 3
        default: return nil
        }
    }

    /// 多久没有新事件就算这一步结束
    public var quietSeconds: Double { (holdSeconds ?? 0) + 2.0 }
    /// 最多等多久
    public var timeoutSeconds: Double { (holdSeconds ?? 0) + 10.0 }
}

/// 一个「控件」（某通道上的某个键）在一次手势里的表现。
public struct ControlSummary: Codable, Sendable, Equatable {
    public var channel: ProbeEvent.Channel
    public var device: String?
    public var control: String
    public var downs = 0
    public var ups = 0
    public var triggers = 0
    public var repeats = 0
    public var changes = 0
    /// 每次「按下 → 松开」的时长（秒）
    public var holdDurations: [Double] = []

    public var id: String { "\(channel.rawValue)|\(device ?? "")|\(control)" }
    public var hasRelease: Bool { ups > 0 }
    public var presses: Int { max(downs, holdDurations.count) + triggers }

    public var label: String {
        var text = "\(Self.channelTitle(channel))：\(control)"
        if let device, channel == .hid || channel == .audio { text = "\(Self.channelTitle(channel))：\(device) · \(control)" }
        return text
    }

    static func channelTitle(_ channel: ProbeEvent.Channel) -> String {
        ProbeEvent(t: 0, channel: channel, control: "", phase: .value).channelTitle
    }
}

public struct GestureResult: Codable, Sendable {
    public enum Firmware: String, Codable, Sendable {
        /// 没发现固件插手
        case none
        /// 固件自己识别了这个手势，发出了和单击不同的键
        case rewritten
        /// 单击有事件，这个手势却什么都没有，疑似被固件占用
        case suspected
        /// 用户看到设备有反应（切模式、关机、配对），或者设备断开了
        case occupied
    }

    public var gesture: Gesture
    public var skipped = false
    public var controls: [ControlSummary] = []
    public var hasRelease = false
    public var longestHold: Double?
    public var deviceDisconnected = false
    public var firmware: Firmware = .none
    /// 用户描述的设备反应（指示灯、切模式、关机等）
    public var firmwareReaction: String?
    public var verdict = ""
    public var events: [ProbeEvent] = []

    public init(gesture: Gesture) {
        self.gesture = gesture
    }

    public var firmwareTitle: String {
        switch firmware {
        case .none: return "—"
        case .rewritten: return "固件改写"
        case .suspected: return "疑似占用"
        case .occupied: return "被固件占用"
        }
    }
}

public enum GestureAnalyzer {
    /// 把一次手势录到的事件归纳成结论。`reference` 是同一个键单击时的结果，用来判断长按、双击有没有被固件改写。
    public static func analyze(_ gesture: Gesture, events: [ProbeEvent], reference: GestureResult? = nil, firmwareReaction: String? = nil) -> GestureResult {
        var result = GestureResult(gesture: gesture)
        result.events = events
        result.firmwareReaction = firmwareReaction?.isEmpty == true ? nil : firmwareReaction
        result.controls = summarize(events)
        result.hasRelease = result.controls.contains(where: \.hasRelease)
        result.longestHold = result.controls.flatMap(\.holdDurations).max()
        result.deviceDisconnected = events.contains { $0.channel == .device && $0.phase == .removed }

        let keyControls = result.controls.filter { $0.channel != .audio || $0.control.hasPrefix("音量") || $0.control.hasPrefix("静音") }
        let referenceIDs = Set(reference?.controls.map(\.id) ?? [])
        let rewritten = gesture != .single && !referenceIDs.isEmpty && !keyControls.isEmpty
            && keyControls.contains { !referenceIDs.contains($0.id) }

        if result.deviceDisconnected || result.firmwareReaction != nil {
            result.firmware = .occupied
        } else if keyControls.isEmpty, !(reference?.controls.isEmpty ?? true) {
            result.firmware = .suspected
        } else if rewritten {
            result.firmware = .rewritten
        }
        result.verdict = verdict(gesture, result: result, keyControls: keyControls, referenceIDs: referenceIDs)
        return result
    }

    static func summarize(_ events: [ProbeEvent]) -> [ControlSummary] {
        var order: [String] = []
        var summaries: [String: ControlSummary] = [:]
        var openSince: [String: Double] = [:]
        for event in events.sorted(by: { $0.t < $1.t }) where event.channel != .hidReport && event.channel != .device {
            if event.channel == .hid && event.phase == .value { continue }
            var summary = summaries[key(event)] ?? ControlSummary(channel: event.channel, device: event.device, control: event.control)
            let id = summary.id
            if summaries[id] == nil { order.append(id) }
            switch event.phase {
            case .down:
                summary.downs += 1
                if openSince[id] == nil { openSince[id] = event.t }
            case .up:
                summary.ups += 1
                if let start = openSince.removeValue(forKey: id) {
                    summary.holdDurations.append(((event.t - start) * 1000).rounded() / 1000)
                }
            case .repeat: summary.repeats += 1
            case .trigger: summary.triggers += 1
            case .change, .value, .added, .removed: summary.changes += 1
            }
            summaries[id] = summary
        }
        return order.compactMap { summaries[$0] }
    }

    private static func key(_ event: ProbeEvent) -> String {
        "\(event.channel.rawValue)|\(event.device ?? "")|\(event.control)"
    }

    private static func verdict(_ gesture: Gesture, result: GestureResult, keyControls: [ControlSummary], referenceIDs: Set<String>) -> String {
        var parts: [String] = []
        if result.deviceDisconnected { parts.append("测试中设备断开或切换了模式") }
        if let reaction = result.firmwareReaction { parts.append("设备自己有反应：\(reaction)") }
        guard !keyControls.isEmpty else {
            parts.append("没读到任何按键事件")
            return parts.joined(separator: "；")
        }
        let main = keyControls.max { $0.presses < $1.presses } ?? keyControls[0]
        switch gesture {
        case .single:
            if main.hasRelease {
                parts.append(main.presses > 1 ? "一次单击读到 \(main.presses) 次按下" : "能读到按下和松开")
            } else if main.triggers > 0 {
                parts.append("只有一次性的触发，没有松开")
            } else if main.downs > 0 {
                parts.append("只有按下，没有松开")
            } else {
                parts.append("只有数值变化（\(main.changes) 次）")
            }
        case .double:
            if main.presses >= 2 {
                parts.append("能读到 \(main.presses) 次按下，App 可以自己识别双击")
            } else {
                parts.append("只读到 1 次，第二下可能被固件合并或吞掉")
            }
        case .long1, .long3:
            let target = gesture.holdSeconds ?? 1
            if let hold = main.holdDurations.max(), hold >= target * 0.6 {
                parts.append(String(format: "能读到按住时长（最长 %.2f 秒）", hold))
            } else if main.repeats > 0 {
                parts.append("按住期间自动连发 \(main.repeats) 次，可以用连发推算按住时长")
            } else if main.hasRelease {
                parts.append(String(format: "只有瞬时的按下松开（%.2f 秒），读不到按住时长", main.holdDurations.max() ?? 0))
            } else {
                parts.append("只有一次性的触发，读不到按住时长")
            }
        }
        let others = keyControls.filter { !referenceIDs.contains($0.id) }
        if gesture != .single, !referenceIDs.isEmpty, !others.isEmpty {
            parts.append("发出了和单击不同的键：" + others.map(\.label).joined(separator: "、"))
        }
        return parts.joined(separator: "；")
    }
}
