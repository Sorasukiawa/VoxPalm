import Foundation

/// 设备示意图：画一个设备外形，按键位置用相对坐标（0…1，相对设备外框），界面在旁边拉线标注每个键做什么。
/// 只画设备类别的示意形状，不用厂商产品图；按键位置以实物为准。
public struct DeviceDiagram: Hashable, Sendable, Identifiable {
    public enum Body: String, Codable, CaseIterable, Sendable {
        /// 电视遥控器：细长，有方向键
        case remote
        /// 带触摸板的遥控器（Siri Remote 一类）
        case touchRemote
        /// 无线麦发射器
        case micTransmitter
        /// 翻页笔
        case presenter
        /// 脚踏板
        case footPedal
        /// 键盘上的媒体键那一排
        case mediaKeys
        /// 不知道长什么样：按学到的键排成一列
        case generic

        public var title: String {
            switch self {
            case .remote: return "电视遥控器"
            case .touchRemote: return "触摸板遥控器"
            case .micTransmitter: return "无线麦发射器"
            case .presenter: return "翻页笔"
            case .footPedal: return "脚踏板"
            case .mediaKeys: return "键盘媒体键"
            case .generic: return "通用按键"
            }
        }

        /// 设备摆在中间、标注在左右两边；宽的设备（脚踏板、媒体键）标注在上下。
        public var isWide: Bool { self == .footPedal || self == .mediaKeys }

        /// 宽 / 高
        public var aspect: Double {
            switch self {
            case .remote: return 0.27
            case .touchRemote: return 0.25
            case .micTransmitter: return 0.66
            case .presenter: return 0.22
            case .footPedal: return 2.6
            case .mediaKeys: return 4.2
            case .generic: return 0.42
            }
        }
    }

    public enum Shape: String, Hashable, Sendable {
        /// 圆形按钮
        case round
        /// 长条按钮（音量键、侧键）
        case pill
        /// 方向键的一个方向（画在圆环上）
        case arrow
        /// 触摸板
        case pad
        /// 踏板
        case pedal
        /// 键盘键帽
        case key
    }

    public struct Spot: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        /// 按键中心，相对设备外框（0…1）；x 为 0 或 1 表示在侧面
        public let x: Double
        public let y: Double
        /// 按键大小，相对设备宽度
        public let size: Double
        public let shape: Shape
        /// 画在按键上的 SF Symbol
        public let symbol: String?
        /// 已知对应的键（适配模块知道时直接给；不知道的由用户学键）
        public let button: ButtonID?
        /// 被固件占用的手势，例如「长按 3 秒：切模式」
        public let reserved: [String]

        public init(id: String, name: String, x: Double, y: Double, size: Double = 0.24, shape: Shape = .round,
                    symbol: String? = nil, button: ButtonID? = nil, reserved: [String] = []) {
            self.id = id
            self.name = name
            self.x = x
            self.y = y
            self.size = size
            self.shape = shape
            self.symbol = symbol
            self.button = button
            self.reserved = reserved
        }

        public var isOnSide: Bool { x <= 0.001 || x >= 0.999 }
    }

    public let id: String
    public let title: String
    public let body: Body
    public let spots: [Spot]
    /// 只有短按、没有松开的设备，长按那一列不能用
    public let reportsRelease: Bool

    public init(id: String, title: String, body: Body, spots: [Spot], reportsRelease: Bool = true) {
        self.id = id
        self.title = title
        self.body = body
        self.spots = spots
        self.reportsRelease = reportsRelease
    }
}

// MARK: - 开源仓库自带的示意图

public extension DeviceDiagram {
    static func template(_ body: Body) -> DeviceDiagram {
        switch body {
        case .remote: return remote
        case .touchRemote: return touchRemote
        case .micTransmitter: return micTransmitter
        case .presenter: return presenter
        case .footPedal: return footPedal
        case .mediaKeys: return mediaKeys
        case .generic: return generic(buttons: [])
        }
    }

    static let remote = DeviceDiagram(id: "remote", title: "电视遥控器", body: .remote, spots: [
        Spot(id: "power", name: "电源键", x: 0.5, y: 0.06, size: 0.2, symbol: "power"),
        Spot(id: "voice", name: "语音键", x: 0.5, y: 0.15, size: 0.26, symbol: "mic.fill"),
        Spot(id: "up", name: "方向上", x: 0.5, y: 0.255, size: 0.2, shape: .arrow, symbol: "chevron.up"),
        Spot(id: "left", name: "方向左", x: 0.23, y: 0.335, size: 0.2, shape: .arrow, symbol: "chevron.left"),
        Spot(id: "ok", name: "确认键", x: 0.5, y: 0.335, size: 0.3, symbol: nil),
        Spot(id: "right", name: "方向右", x: 0.77, y: 0.335, size: 0.2, shape: .arrow, symbol: "chevron.right"),
        Spot(id: "down", name: "方向下", x: 0.5, y: 0.415, size: 0.2, shape: .arrow, symbol: "chevron.down"),
        Spot(id: "back", name: "返回键", x: 0.27, y: 0.52, size: 0.24, symbol: "arrow.uturn.backward"),
        Spot(id: "home", name: "主页键", x: 0.73, y: 0.52, size: 0.24, symbol: "house"),
        Spot(id: "menu", name: "菜单键", x: 0.5, y: 0.6, size: 0.24, symbol: "line.3.horizontal"),
        Spot(id: "volumeUp", name: "音量 +", x: 0.5, y: 0.7, size: 0.3, shape: .pill, symbol: "plus"),
        Spot(id: "volumeDown", name: "音量 −", x: 0.5, y: 0.79, size: 0.3, shape: .pill, symbol: "minus"),
    ])

    static let touchRemote = DeviceDiagram(id: "touchRemote", title: "触摸板遥控器", body: .touchRemote, spots: [
        Spot(id: "pad", name: "触摸板（按下）", x: 0.5, y: 0.19, size: 0.82, shape: .pad),
        Spot(id: "side", name: "侧面语音键", x: 1, y: 0.3, size: 0.14, shape: .pill),
        Spot(id: "back", name: "返回键", x: 0.28, y: 0.44, size: 0.3, symbol: "chevron.left"),
        Spot(id: "home", name: "主页键", x: 0.72, y: 0.44, size: 0.3, symbol: "tv"),
        Spot(id: "playPause", name: "播放 / 暂停", x: 0.28, y: 0.56, size: 0.3, symbol: "playpause.fill"),
        Spot(id: "volumeUp", name: "音量 +", x: 0.72, y: 0.56, size: 0.3, symbol: "plus"),
        Spot(id: "mute", name: "静音", x: 0.28, y: 0.68, size: 0.3, symbol: "speaker.slash.fill"),
        Spot(id: "volumeDown", name: "音量 −", x: 0.72, y: 0.68, size: 0.3, symbol: "minus"),
    ])

    static let micTransmitter = DeviceDiagram(id: "micTransmitter", title: "无线麦发射器", body: .micTransmitter, spots: [
        Spot(id: "power", name: "电源键", x: 0, y: 0.38, size: 0.12, shape: .pill),
        Spot(id: "record", name: "录制键", x: 0.5, y: 0.72, size: 0.24, symbol: "circle.fill"),
        Spot(id: "link", name: "连接键", x: 1, y: 0.38, size: 0.12, shape: .pill),
    ])

    static let presenter = DeviceDiagram(id: "presenter", title: "翻页笔", body: .presenter, spots: [
        Spot(id: "laser", name: "激光 / 聚光", x: 0.5, y: 0.14, size: 0.42, symbol: "light.max"),
        Spot(id: "previous", name: "上一页", x: 0.5, y: 0.36, size: 0.5, symbol: "chevron.up"),
        Spot(id: "next", name: "下一页", x: 0.5, y: 0.56, size: 0.5, symbol: "chevron.down"),
        Spot(id: "screen", name: "黑屏 / 放映", x: 0.5, y: 0.76, size: 0.42, symbol: "play.rectangle"),
    ])

    static let footPedal = DeviceDiagram(id: "footPedal", title: "脚踏板", body: .footPedal, spots: [
        Spot(id: "left", name: "左踏板", x: 0.19, y: 0.52, size: 0.27, shape: .pedal),
        Spot(id: "middle", name: "中踏板", x: 0.5, y: 0.52, size: 0.27, shape: .pedal),
        Spot(id: "right", name: "右踏板", x: 0.81, y: 0.52, size: 0.27, shape: .pedal),
    ])

    /// 系统媒体键：键码是公开头文件里的 NX_KEYTYPE_*，不用学键。
    static let mediaKeys = DeviceDiagram(id: "mediaKeys", title: "键盘媒体键", body: .mediaKeys, spots: [
        Spot(id: "previous", name: "上一首（F7）", x: 0.09, y: 0.5, size: 0.14, shape: .key, symbol: "backward.fill", button: .media(18)),
        Spot(id: "playPause", name: "播放 / 暂停（F8）", x: 0.254, y: 0.5, size: 0.14, shape: .key, symbol: "playpause.fill", button: .media(16)),
        Spot(id: "next", name: "下一首（F9）", x: 0.418, y: 0.5, size: 0.14, shape: .key, symbol: "forward.fill", button: .media(17)),
        Spot(id: "mute", name: "静音（F10）", x: 0.582, y: 0.5, size: 0.14, shape: .key, symbol: "speaker.slash.fill", button: .media(7)),
        Spot(id: "volumeDown", name: "音量 −（F11）", x: 0.746, y: 0.5, size: 0.14, shape: .key, symbol: "speaker.wave.1.fill", button: .media(1)),
        Spot(id: "volumeUp", name: "音量 +（F12）", x: 0.91, y: 0.5, size: 0.14, shape: .key, symbol: "speaker.wave.3.fill", button: .media(0)),
    ])

    /// 不知道长什么样的设备：把学到的键竖着排。
    static func generic(buttons: [(ButtonID, String)], reportsRelease: Bool = true) -> DeviceDiagram {
        let count = max(buttons.count, 1)
        let spots = buttons.enumerated().map { index, item in
            Spot(id: item.0.rawValue, name: item.1, x: 0.5, y: 0.14 + 0.72 * (Double(index) + 0.5) / Double(count),
                 size: min(0.5, 0.9 / Double(count) * 2.2), button: item.0)
        }
        return DeviceDiagram(id: "generic", title: "通用按键", body: .generic, spots: spots, reportsRelease: reportsRelease)
    }

    /// 按设备的说明猜它长什么样，用户可以在界面里改。
    static func guessBody(for device: ControlDevice) -> Body {
        if device.id == SystemKeysControlSource.mediaDeviceID { return .mediaKeys }
        if device.sourceID == "hid" {
            if device.detail.contains("触控") || device.detail.contains("Digitizer") { return .touchRemote }
            if device.detail.contains("媒体键") { return .remote }
            if device.detail.contains("键盘") { return .presenter }
        }
        return .generic
    }
}
