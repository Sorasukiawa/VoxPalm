import Foundation

public extension DeviceDiagram {
    static let dualSense = gamepad(edge: false)
    static let dualSenseEdge = gamepad(edge: true)

    /// 按 Sony 官方正面/背面说明图独立绘制；顶部肩键、底部背键展开，方便逐键点选。
    private static func gamepad(edge: Bool) -> DeviceDiagram {
        func key(_ id: String, _ box: Box, _ shape: Shape = .circle, symbol: String? = nil) -> Spot {
            let button = DualSenseInput.button(id)
            return Spot(id, DualSenseInput.label(button), box, shape, .blackKey, symbol: symbol, button: button)
        }
        var parts: [Part] = [
            Part(Box(0, 20, 160, 98), .gamepad, .aluminum),
            Part(Box(51, 26, 58, 32), .rounded(7), edge ? .blackKey : .lightKey),
            Part(.circle(31, 57, 33), .circle, .recess),
            Part(.circle(129, 57, 33), .circle, .recess),
            Part(.circle(54, 79, 27), .circle, .recess),
            Part(.circle(106, 79, 27), .circle, .recess),
            Part(.center(80, 64, 15, 2), .capsule, .grille),
            Part(.center(80, 97, 22, 2), .capsule, .port),
            Part(.center(80, 9, 38, 7), .rounded(0), .caption, text: "肩键（展开）"),
        ]
        var spots: [Spot] = [
            key("l2", .center(24, 5, 20, 9), .rounded(3), symbol: "l2.button.roundedtop.horizontal"),
            key("r2", .center(136, 5, 20, 9), .rounded(3), symbol: "r2.button.roundedtop.horizontal"),
            key("l1", .center(24, 16, 24, 9), .rounded(3), symbol: "l1.button.roundedbottom.horizontal"),
            key("r1", .center(136, 16, 24, 9), .rounded(3), symbol: "r1.button.roundedbottom.horizontal"),
            key("up", .center(31, 47, 8, 10), .rounded(2), symbol: "arrowtriangle.up.fill"),
            key("left", .center(21, 57, 10, 8), .rounded(2), symbol: "arrowtriangle.left.fill"),
            key("right", .center(41, 57, 10, 8), .rounded(2), symbol: "arrowtriangle.right.fill"),
            key("down", .center(31, 67, 8, 10), .rounded(2), symbol: "arrowtriangle.down.fill"),
            key("triangle", .circle(129, 46, 10), symbol: "triangle"),
            key("square", .circle(118, 57, 10), symbol: "square"),
            key("circle", .circle(140, 57, 10), symbol: "circle"),
            key("cross", .circle(129, 68, 10), symbol: "xmark"),
            key("touchpad", .center(80, 41, 51, 27), .rounded(5)),
            key("create", .center(45, 35, 4, 10), .capsule, symbol: "line.3.horizontal"),
            key("options", .center(115, 35, 4, 10), .capsule, symbol: "line.3.horizontal"),
            key("l3", .circle(54, 79, 19), symbol: "l.joystick.press.down"),
            key("r3", .circle(106, 79, 19), symbol: "r.joystick.press.down"),
            key("ps", .circle(80, 76, 8), symbol: "house"),
            key("mute", .center(80, 88, 10, 4), .capsule, symbol: "mic.slash"),
        ]
        if edge {
            spots += [
                key("fnLeft", .center(54, 96, 9, 7), .rounded(2)),
                key("fnRight", .center(106, 96, 9, 7), .rounded(2)),
                key("backLeft", .center(53, 132, 24, 10), .capsule),
                key("backRight", .center(107, 132, 24, 10), .capsule),
            ]
            parts.append(Part(.center(80, 132, 25, 8), .rounded(0), .caption, text: "背键（展开）"))
        }
        return DeviceDiagram(id: edge ? "dualsense-edge" : "dualsense", title: edge ? "DualSense Edge（DSE）" : "DualSense（DS5）",
                             width: 160, height: edge ? 144 : 120, parts: parts, spots: spots,
                             note: "按键适配待真机验证；触摸板这里只读按下，不移动鼠标。" +
                                (edge ? "Fn、背键和静音键需要完整输入报告；板载配置可能同时触发其他键。" : "蓝牙静音键需要完整输入报告。") +
                                "掌声不独占手柄，游戏仍会收到按键，用游戏时请暂停监听")
    }

    static let siriRemote1 = DeviceDiagram(
        id: "siri-remote-1", title: "Siri Remote（第一代）", width: 38, height: 124,
        parts: [
            Part(Box(0, 0, 38, 124), .rounded(5), .graphite),
            Part(Box(1, 1, 36, 53), .rounded(4), .blackKey),
            Part(.center(27, 86, 12, 28), .capsule, .blackKey),
        ],
        spots: [
            Spot("ok", "触摸面按下", .center(19, 28, 30, 42), .rounded(4), .zone),
            Spot("back", "MENU 键", .circle(11, 64, 12), symbol: "chevron.left"),
            Spot("tv", "TV 键", .circle(27, 64, 12), symbol: "tv"),
            Spot("siri", "Siri 键", .circle(11, 80, 12), symbol: "mic"),
            Spot("playPause", "播放 / 暂停", .circle(11, 96, 12), symbol: "playpause"),
            Spot("volumeUp", "音量 +", .circle(27, 79, 10), .circle, .zone, symbol: "plus"),
            Spot("volumeDown", "音量 −", .circle(27, 93, 10), .circle, .zone, symbol: "minus"),
        ], note: "按键需逐个学键并实测；滑动触摸和遥控器麦克风尚未接入，收音请选择 Mac 或外接麦克风"
    )
}
