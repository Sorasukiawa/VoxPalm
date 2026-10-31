import Foundation

/// 设备示意图：照真实产品的尺寸和按键位置画的矢量线稿，界面在旁边拉线标注每个键做什么。
/// 坐标单位是毫米（取自产品规格和说明书线稿），渲染时整体缩放。按键在侧面的设备把侧面展开画在正面旁边。
/// 品牌标志画在实物印标志的位置：官方版画真的标志图形（私有包登记），开源版用普通字体印品牌名。
public struct DeviceDiagram: Hashable, Sendable, Identifiable {
    /// 左上角 + 宽高，单位同 `width` / `height`
    public struct Box: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double

        public init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
        }

        public static func center(_ cx: Double, _ cy: Double, _ w: Double, _ h: Double) -> Box { Box(cx - w / 2, cy - h / 2, w, h) }
        public static func circle(_ cx: Double, _ cy: Double, _ d: Double) -> Box { center(cx, cy, d, d) }

        public var midX: Double { x + w / 2 }
        public var midY: Double { y + h / 2 }
    }

    public enum Shape: Hashable, Sendable {
        /// 圆角矩形，参数是圆角半径（同单位）
        case rounded(Double)
        case circle
        case capsule
        case gamepad
        case gamepadPanel, gamepadRearPanel, touchpad, functionKey, backPaddle
        /// 方向键的朝向：上、右、下、左分别为 0～3。
        case directional(Int)
    }

    public enum Style: String, Hashable, Sendable {
        /// 机身：银色铝、深灰塑料
        case aluminum, graphite
        /// 手柄白色外壳、亮黑面板和带凹面的橡胶摇杆。
        case shell, glossy, stick
        /// 背夹
        case clip
        /// 按键：黑色、浅色、录制键（红圈）、侧面按键
        case blackKey, lightKey, recordKey, sideKey
        /// 装饰：凹槽、接口、指示灯、网罩、小标记、白色小点、面板下面的说明文字
        case recess, port, led, grille, mark, dot, caption
        /// 机身上印的品牌标志：文字是品牌名；登记了标志图形（`DiagramMarks`）就画图形，没登记就用普通字体印品牌名。
        /// 深色机身上用浅色、浅色机身上用深色
        case printLight, printDark
        /// 不画底色，只在选中或按下时高亮（方向盘的上下左右、音量条的上下半段）
        case zone
    }

    /// 画出来但不能映射的部分（机身、接口、指示灯……）
    public struct Part: Hashable, Sendable {
        public let box: Box
        public let shape: Shape
        public let style: Style
        public let symbol: String?
        public let text: String?

        public init(_ box: Box, _ shape: Shape, _ style: Style, symbol: String? = nil, text: String? = nil) {
            self.box = box
            self.shape = shape
            self.style = style
            self.symbol = symbol
            self.text = text
        }
    }

    /// 可以映射的键
    public struct Spot: Hashable, Sendable, Identifiable {
        public let id: String
        public let name: String
        public let box: Box
        public let shape: Shape
        public let style: Style
        /// 画在键上的 SF Symbol
        public let symbol: String?
        /// 已知对应的键（适配模块知道时直接给；不知道的由用户学键）
        public let button: ButtonID?
        /// 被设备固件占用的手势，例如「长按 3 秒：切模式」
        public let reserved: [String]
        /// 没有对应图标时印在键上的短文字。
        public let text: String?

        public init(_ id: String, _ name: String, _ box: Box, _ shape: Shape = .circle, _ style: Style = .blackKey,
                    symbol: String? = nil, button: ButtonID? = nil, reserved: [String] = [], text: String? = nil) {
            self.id = id
            self.name = name
            self.box = box
            self.shape = shape
            self.style = style
            self.symbol = symbol
            self.button = button
            self.reserved = reserved
            self.text = text
        }
    }

    public let id: String
    public let title: String
    public let width: Double
    public let height: Double
    public let parts: [Part]
    public let spots: [Spot]
    /// 只有短按、没有松开的设备，长按那一列不能用
    public let reportsRelease: Bool
    /// 画法说明，例如「左右两块是展开的侧面」
    public let note: String?

    public init(id: String, title: String, width: Double, height: Double, parts: [Part], spots: [Spot],
                reportsRelease: Bool = true, note: String? = nil) {
        self.id = id
        self.title = title
        self.width = width
        self.height = height
        self.parts = parts
        self.spots = spots
        self.reportsRelease = reportsRelease
        self.note = note
    }

    /// 宽的设备（展开的侧面、脚踏板、媒体键）标注在上下，竖的标注在左右。
    public var isWide: Bool { width / height > 1.2 }

    /// 引导里建议用来说话的键：遥控器的确认键、无线麦的录制键、脚踏板中间那块等，没有这些就用第一个键。
    public var recommendedTalkSpot: Spot? {
        let preferred = ["r1", "ok", "record", "middle", "laser", "playPause", "screen"]
        for id in preferred { if let spot = spots.first(where: { $0.id == id }) { return spot } }
        return spots.first
    }
}

// MARK: - 开源仓库自带的示意图

public extension DeviceDiagram {
    /// 设置里「外形」可以选的（适配模块自带的示意图不在这里）
    static let choices: [DeviceDiagram] = [xiaomiRemote2, siriRemote, siriRemote1, dualSense, dualSenseEdge, remote, presenter, footPedal, micTransmitter, generic(buttons: [])]

    static func choice(id: String) -> DeviceDiagram? {
        id == mediaKeys.id ? mediaKeys : choices.first { $0.id == id }
    }

    /// 小米蓝牙遥控器 2（macOS 里显示为 RC001，VID 0x2717 PID 0x32B8）。
    /// 照小米有品的正面产品图量的比例：宽 36、长约 141，顶部电源键和语音键是浅色，其余是黑色。
    static let xiaomiRemote2 = DeviceDiagram(
        id: "xiaomi-remote-2", title: "小米蓝牙遥控器 2", width: 36, height: 141,
        parts: [
            Part(Box(0, 0, 36, 141), .rounded(3), .aluminum),
            Part(.circle(18, 32, 30), .circle, .blackKey),
            Part(.circle(18, 19.6, 0.8), .circle, .mark),
            Part(.circle(18, 44.4, 0.8), .circle, .mark),
            Part(.circle(5.6, 32, 0.8), .circle, .mark),
            Part(.circle(30.4, 32, 0.8), .circle, .mark),
            Part(.center(25.7, 61, 11.5, 25.4), .capsule, .blackKey),
            Part(.center(18, 105.8, 3.2, 3.2), .rounded(0.7), .mark, text: "N"),
            Part(.center(18, 129.4, 12.4, 2.2), .rounded(0), .printDark, text: "xiaomi"),
        ],
        spots: [
            Spot("power", "电源键", .circle(8.6, 9.9, 7.2), .circle, .lightKey, symbol: "power"),
            Spot("voice", "语音键", .circle(27.4, 9.9, 7.2), .circle, .lightKey, symbol: "mic"),
            Spot("up", "方向上", .circle(18, 22, 6.5), .circle, .zone),
            Spot("left", "方向左", .circle(8, 32, 6.5), .circle, .zone),
            Spot("ok", "确认键", .circle(18, 32, 16), .circle, .blackKey),
            Spot("right", "方向右", .circle(28, 32, 6.5), .circle, .zone),
            Spot("down", "方向下", .circle(18, 42, 6.5), .circle, .zone),
            Spot("back", "返回键", .circle(10.3, 54.3, 11.5), .circle, .blackKey, symbol: "chevron.left"),
            Spot("volumeUp", "音量 +", .circle(25.7, 54.3, 9), .circle, .zone, symbol: "plus"),
            Spot("home", "主页键", .circle(10.3, 67.5, 11.5), .circle, .blackKey, symbol: "house"),
            Spot("volumeDown", "音量 −", .circle(25.7, 67.7, 9), .circle, .zone, symbol: "minus"),
            Spot("menu", "菜单键", .circle(10.3, 81.2, 11.5), .circle, .blackKey, symbol: "line.3.horizontal"),
            Spot("tv", "TV 键", .circle(25.7, 81.2, 11.5), .circle, .blackKey, symbol: "tv"),
        ]
    )

    /// Apple Siri Remote（第 2、3 代，2021 年以后的铝机身款）。规格 35 × 136 × 9.25 毫米。
    /// 位置是从 Apple 技术规格页的正面图（111844_siri-remote-3rd.png，251 × 960 像素）逐像素量的：
    /// 顶部正中一条小横杠，右上角浅色电源键，触控板外圈四个白点，Siri 键在右侧面（画成伸出右边的一小段）。
    static let siriRemote = DeviceDiagram(
        id: "siri-remote", title: "Siri Remote", width: 36.6, height: 136,
        parts: [
            Part(Box(0, 0, 35, 136), .rounded(5.7), .aluminum),
            Part(.center(17.5, 6.9, 2.0, 0.85), .capsule, .port),
            Part(.circle(17.5, 28.6, 31), .circle, .blackKey),
            Part(.circle(17.5, 14.9, 0.7), .circle, .dot),
            Part(.circle(17.5, 42.3, 0.7), .circle, .dot),
            Part(.circle(3.8, 28.6, 0.7), .circle, .dot),
            Part(.circle(31.2, 28.6, 0.7), .circle, .dot),
            Part(.center(25, 73.7, 11.7, 27), .capsule, .blackKey),
        ],
        spots: [
            Spot("power", "电源键", .circle(28, 6.8, 6), .circle, .lightKey, symbol: "power", reserved: ["macOS 可能同时锁屏或睡眠；不建议映射"]),
            Spot("siri", "Siri 键（右侧面）", .center(35.5, 28.7, 1.4, 14.7), .capsule, .sideKey),
            Spot("up", "触控板上", .circle(17.5, 16.4, 5.5), .circle, .zone),
            Spot("left", "触控板左", .circle(5.3, 28.6, 5.5), .circle, .zone),
            Spot("ok", "触控板中间（按下）", .circle(17.5, 28.6, 17.8), .circle, .blackKey),
            Spot("right", "触控板右", .circle(29.7, 28.6, 5.5), .circle, .zone),
            Spot("down", "触控板下", .circle(17.5, 40.8, 5.5), .circle, .zone),
            Spot("back", "返回键", .circle(10, 51.5, 12.2), .circle, .blackKey, symbol: "chevron.left"),
            Spot("tv", "TV 键", .circle(25, 51.5, 12.2), .circle, .blackKey, symbol: "tv"),
            Spot("playPause", "播放 / 暂停", .circle(10, 66.3, 12.2), .circle, .blackKey, symbol: "playpause"),
            Spot("volumeUp", "音量 +", .circle(25, 66.3, 9), .circle, .zone, symbol: "plus"),
            Spot("mute", "静音", .circle(10, 81.1, 12.2), .circle, .blackKey, symbol: "speaker.slash"),
            Spot("volumeDown", "音量 −", .circle(25, 81.1, 9), .circle, .zone, symbol: "minus"),
        ], note: "第二、三代共用外形；按键需逐个学键并实测。方向环指实体按下，滑动触摸和遥控器麦克风尚未接入；系统可能同时响应音量、电源或播放键"
    )

    /// 通用电视遥控器（不知道具体型号时用）
    static let remote = DeviceDiagram(
        id: "remote", title: "电视遥控器（通用）", width: 44, height: 165,
        parts: [
            Part(Box(0, 0, 44, 165), .rounded(20), .graphite),
            Part(.circle(22, 55, 38), .circle, .recess),
        ],
        spots: [
            Spot("power", "电源键", .circle(22, 10, 8), symbol: "power"),
            Spot("voice", "语音键", .circle(22, 24, 10), symbol: "mic.fill"),
            Spot("up", "方向上", .circle(22, 42, 8), .circle, .zone, symbol: "chevron.up"),
            Spot("left", "方向左", .circle(9, 55, 8), .circle, .zone, symbol: "chevron.left"),
            Spot("ok", "确认键", .circle(22, 55, 15)),
            Spot("right", "方向右", .circle(35, 55, 8), .circle, .zone, symbol: "chevron.right"),
            Spot("down", "方向下", .circle(22, 68, 8), .circle, .zone, symbol: "chevron.down"),
            Spot("back", "返回键", .circle(12, 86, 10), symbol: "arrow.uturn.backward"),
            Spot("home", "主页键", .circle(32, 86, 10), symbol: "house"),
            Spot("menu", "菜单键", .circle(22, 99, 10), symbol: "line.3.horizontal"),
            Spot("volumeUp", "音量 +", .center(22, 115, 16, 8), .capsule, symbol: "plus"),
            Spot("volumeDown", "音量 −", .center(22, 129, 16, 8), .capsule, symbol: "minus"),
        ]
    )

    static let presenter = DeviceDiagram(
        id: "presenter", title: "翻页笔", width: 28, height: 120,
        parts: [
            Part(Box(0, 0, 28, 120), .capsule, .graphite),
            Part(.center(14, 5, 9, 1.8), .capsule, .led),
        ],
        spots: [
            Spot("laser", "激光 / 聚光", .circle(14, 19, 11), symbol: "light.max"),
            Spot("previous", "上一页", .circle(14, 43, 14), symbol: "chevron.up"),
            Spot("next", "下一页", .circle(14, 66, 14), symbol: "chevron.down"),
            Spot("screen", "黑屏 / 放映", .circle(14, 89, 11), symbol: "play.rectangle"),
        ]
    )

    static let footPedal = DeviceDiagram(
        id: "foot-pedal", title: "脚踏板", width: 260, height: 100,
        parts: [Part(Box(0, 0, 260, 100), .rounded(12), .graphite)],
        spots: [
            Spot("left", "左踏板", .center(45, 50, 70, 74), .rounded(9)),
            Spot("middle", "中踏板", .center(130, 50, 70, 74), .rounded(9)),
            Spot("right", "右踏板", .center(215, 50, 70, 74), .rounded(9)),
        ]
    )

    /// 通用无线麦发射器（不知道具体型号时用）：正面一个键，两侧各一个键。
    static let micTransmitter = DeviceDiagram(
        id: "mic-transmitter", title: "无线麦发射器（通用）", width: 35, height: 46,
        parts: [
            Part(Box(2, 0, 31, 46), .rounded(7), .graphite),
            Part(Box(7, 2, 21, 3), .rounded(1.5), .grille),
        ],
        spots: [
            Spot("power", "左侧键", .center(1.2, 18, 2, 8), .capsule, .sideKey),
            Spot("record", "正面键", .circle(17.5, 32, 8), .circle, .recordKey),
            Spot("link", "右侧键", .center(33.8, 18, 2, 8), .capsule, .sideKey),
        ]
    )

    /// 系统媒体键：键码是公开头文件里的 NX_KEYTYPE_*，不用学键。
    static let mediaKeys: DeviceDiagram = {
        let keys: [(String, String, String, Int)] = [
            ("previous", "上一首（F7）", "backward.fill", 18), ("playPause", "播放 / 暂停（F8）", "playpause.fill", 16),
            ("next", "下一首（F9）", "forward.fill", 17), ("mute", "静音（F10）", "speaker.slash.fill", 7),
            ("volumeDown", "音量 −（F11）", "speaker.wave.1.fill", 1), ("volumeUp", "音量 +（F12）", "speaker.wave.3.fill", 0),
        ]
        return DeviceDiagram(
            id: "media-keys", title: "键盘媒体键", width: 300, height: 60,
            parts: [Part(Box(0, 0, 300, 60), .rounded(8), .graphite)],
            spots: keys.enumerated().map { index, key in
                Spot(key.0, key.1, .center(27 + Double(index) * 49.2, 30, 42, 40), .rounded(6), symbol: key.2, button: .media(key.3))
            }
        )
    }()

    /// 不知道长什么样的设备：把学到的键竖着排。
    static func generic(buttons: [(ButtonID, String)], reportsRelease: Bool = true) -> DeviceDiagram {
        let count = Double(max(buttons.count, 1))
        let height = 30 + 26 * count
        return DeviceDiagram(
            id: "generic", title: "通用按键", width: 46, height: height,
            parts: [Part(Box(0, 0, 46, height), .rounded(14), .graphite)],
            spots: buttons.enumerated().map { index, item in
                Spot(item.0.rawValue, item.1, .circle(23, 28 + 26 * Double(index), 18), button: item.0)
            },
            reportsRelease: reportsRelease
        )
    }

    /// 按设备的说明猜它长什么样，用户可以在界面里改。
    static func guess(for device: ControlDevice) -> DeviceDiagram {
        if device.id == SystemKeysControlSource.mediaDeviceID { return mediaKeys }
        if device.sourceID == "hid" {
            if device.detail.contains("0x2717:0x32B8") { return xiaomiRemote2 }
            if device.detail.contains("0x004C:0x0266") || device.detail.contains("0x004C:0x026D") { return siriRemote1 }
            if device.detail.contains("0x004C:0x0314") || device.detail.contains("0x004C:0x0315") { return siriRemote }
            if device.detail.contains("0x054C:0x0CE6") { return dualSense }
            if device.detail.contains("0x054C:0x0DF2") { return dualSenseEdge }
            if device.detail.contains("媒体键") { return remote }
            if device.detail.contains("键盘") { return presenter }
        }
        return generic(buttons: [])
    }
}
