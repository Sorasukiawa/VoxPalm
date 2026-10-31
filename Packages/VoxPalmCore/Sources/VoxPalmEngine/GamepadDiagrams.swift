import Foundation

public extension DeviceDiagram {
    static let dualSense = gamepad(edge: false)
    static let dualSenseEdge = gamepad(edge: true)

    /// 按 Sony 官方正面/背面说明图独立绘制；顶部肩键、底部背键展开，方便逐键点选。
    private static func gamepad(edge: Bool) -> DeviceDiagram {
        func key(_ id: String, _ box: Box, _ shape: Shape = .circle, style: Style = .blackKey, symbol: String? = nil, text: String? = nil) -> Spot {
            let button = DualSenseInput.button(id)
            return Spot(id, DualSenseInput.label(button), box, shape, style, symbol: symbol, button: button, text: text)
        }
        var parts: [Part] = [
            Part(Box(0, 16, 160, 104), .gamepad, .shell),
            Part(Box(0, 16, 160, 104), .gamepadPanel, edge ? .glossy : .graphite),
            Part(Box(47.5, 17, 65, 36), .touchpad, .port),
            Part(.circle(55, 68, 27), .circle, .port),
            Part(.circle(105, 68, 27), .circle, .port),
            Part(.center(80, 83, 3.4, 1.2), .capsule, .port),
            Part(.center(80, 7, 38, 7), .rounded(0), .caption, text: "肩键（展开）"),
        ]
        // 扬声器是两排小孔，不是接口或长条按钮。
        for (row, count) in [(0, 6), (1, 5)] {
            for column in 0..<count {
                parts.append(Part(.circle(80 + (Double(column) - Double(count - 1) / 2) * 2.1, 57 + Double(row) * 2, 1.3), .circle, .port))
            }
        }
        let face: Style = edge ? .blackKey : .lightKey
        // 由两款官方正视说明图按外壳宽高归一化；左右键组同高，方向键比右侧四键更紧凑。
        let dpadX = edge ? 31.5 : 31.3
        let faceX = edge ? 128.0 : 128.5
        let buttonY = edge ? 45.2 : 45.8
        let dpadRadius = 8.2
        let faceRadius = 11.3
        var spots: [Spot] = [
            key("l2", .center(25, 5, 27, 8), .rounded(3), text: "L2"),
            key("r2", .center(135, 5, 27, 8), .rounded(3), text: "R2"),
            key("l1", .center(25, 14, 32, 7), .rounded(2), text: "L1"),
            key("r1", .center(135, 14, 32, 7), .rounded(2), text: "R1"),
            key("up", .center(dpadX, buttonY - dpadRadius, 7.3, 8.5), .directional(0), style: face, symbol: "arrowtriangle.up.fill"),
            key("left", .center(dpadX - dpadRadius, buttonY, 8.5, 7.3), .directional(3), style: face, symbol: "arrowtriangle.left.fill"),
            key("right", .center(dpadX + dpadRadius, buttonY, 8.5, 7.3), .directional(1), style: face, symbol: "arrowtriangle.right.fill"),
            key("down", .center(dpadX, buttonY + dpadRadius, 7.3, 8.5), .directional(2), style: face, symbol: "arrowtriangle.down.fill"),
            key("triangle", .circle(faceX, buttonY - faceRadius, 10.5), style: face, symbol: "triangle"),
            key("square", .circle(faceX - faceRadius, buttonY, 10.5), style: face, symbol: "square"),
            key("circle", .circle(faceX + faceRadius, buttonY, 10.5), style: face, symbol: "circle"),
            key("cross", .circle(faceX, buttonY + faceRadius, 10.5), style: face, symbol: "xmark"),
            key("touchpad", Box(49, 18, 62, 33), .touchpad, style: edge ? .blackKey : .lightKey),
            key("create", .center(43, 27, 3.5, 7), .capsule, style: .lightKey),
            key("options", .center(117, 27, 3.5, 7), .capsule, style: .lightKey),
            key("l3", .circle(55, 68, 23), style: .stick),
            key("r3", .circle(105, 68, 23), style: .stick),
            key("ps", .center(80, 66, 9, 8), .rounded(2), style: .zone, text: "PS"),
            key("mute", .center(80, 77, 9, 2.5), .capsule),
        ]
        if edge {
            spots += [
                key("fnLeft", .center(55, 86, 12, 6), .functionKey, text: "Fn"),
                key("fnRight", .center(105, 86, 12, 6), .functionKey, text: "Fn"),
                // 背面视角下，握持时的左背键位于图右，右背键位于图左。
                key("backLeft", .center(96, 151, 10, 12), .backPaddle, text: "L"),
                key("backRight", .center(64, 151, 10, 12), .backPaddle, text: "R"),
            ]
            parts += [
                Part(Box(40, 126, 80, 52), .gamepad, .shell),
                Part(Box(40, 126, 80, 52), .gamepadRearPanel, .graphite),
                Part(.center(53, 128, 13, 5), .rounded(2), .blackKey),
                Part(.center(107, 128, 13, 5), .rounded(2), .blackKey),
                Part(.center(59, 137, 1.8, 6), .capsule, .blackKey),
                Part(.center(101, 137, 1.8, 6), .capsule, .blackKey),
                Part(.center(80, 164, 8, 1), .capsule, .port),
                Part(.center(80, 185, 62, 7), .rounded(0), .caption, text: "背面 · 左右背键"),
            ]
        }
        return DeviceDiagram(id: edge ? "dualsense-edge" : "dualsense", title: edge ? "DualSense Edge（DSE）" : "DualSense（DS5）",
                             width: 160, height: edge ? 192 : 124, parts: parts, spots: spots,
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
