import AppKit
import SwiftUI
import VoxPalmEngine

/// 调试用，不开窗口、画完就退出：
/// - `VoxPalm --render-diagrams <目录>`：每种示意图（套上「AI 编程」预设）画成 PNG
/// - `VoxPalm --render-ui <目录>`：菜单栏图标、面板、说话浮窗、设置各页、引导各步，浅色深色各一张
@MainActor
enum UIPreview {
    /// 正在画预览图：不开麦量音量、不进认设备模式
    static var isRendering = false

    static func renderIfRequested() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--render-live"), index + 1 < args.count {
            renderLive(to: URL(fileURLWithPath: args[index + 1]))
        }
        if let index = args.firstIndex(of: "--render-ui"), index + 1 < args.count {
            renderUI(to: URL(fileURLWithPath: args[index + 1]))
        }
        guard let index = args.firstIndex(of: "--render-diagrams"), index + 1 < args.count else { return }
        let directory = URL(fileURLWithPath: args[index + 1])
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var diagrams = DeviceDiagram.choices.map { diagram -> DeviceDiagram in
            diagram.id == "generic"
                ? .generic(buttons: [(ButtonID("key:121"), "按键 PageDown"), (ButtonID("key:116"), "按键 PageUp"), (ButtonID("key:11"), "按键 B")])
                : diagram
        } + [DeviceDiagram.mediaKeys]
        diagrams += PrivateModules.previewDiagrams()
        for diagram in diagrams {
            var buttons: [String: ButtonID] = [:]
            for spot in diagram.spots where spot.id != "menu" {
                buttons[spot.id] = spot.button ?? ButtonID("demo:\(spot.id)")
            }
            let resolved = AppModel.ResolvedDiagram(diagram: diagram, buttons: buttons, isFixed: false, reportsRelease: diagram.reportsRelease)
            var keyMap = KeyMap()
            for binding in AIPreset.bindings(for: resolved) { keyMap.set(binding) }
            let callouts = DiagramCallout.make(diagram: diagram, buttons: buttons, keyMap: keyMap,
                                               reportsRelease: resolved.reportsRelease, learning: nil)
            let selected = diagram.spots.first { ["down", "next", "record"].contains($0.id) }?.id
            // 只画设备本体（不带标注），高 600 点，用来和产品图并排对比。
            let artHeight: CGFloat = 600
            let artWidth = artHeight * diagram.width / diagram.height
            var artLayout = DiagramLayout(diagram: diagram, callouts: [], size: CGSize(width: artWidth, height: artHeight))
            artLayout.device = CGRect(x: 0, y: 0, width: artWidth, height: artHeight)
            artLayout.scale = artHeight / diagram.height
            let art = DeviceArt(diagram: diagram, layout: artLayout, highlighted: [:])
                .frame(width: artWidth, height: artHeight)
                .background(Color(white: 0.07))
            let artRenderer = ImageRenderer(content: art)
            if let image = artRenderer.nsImage, let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: directory.appendingPathComponent("art-\(diagram.id).png"))
            }
            for scheme in [ColorScheme.light, .dark] {
                let view = DeviceDiagramView(diagram: diagram, callouts: callouts, pressed: [], buttons: buttons, selected: selected)
                    .padding(16)
                    .frame(width: 680)
                    .background(scheme == .dark ? Color(white: 0.16) : Color(white: 0.95))
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                      let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { continue }
                let name = "diagram-\(diagram.id)-\(scheme == .dark ? "dark" : "light").png"
                try? png.write(to: directory.appendingPathComponent(name))
            }
        }
        exit(0)
    }
}

extension UIPreview {
    /// 把一个视图放进屏幕外的窗口画成 PNG（这样系统控件也能画出来）。
    static func snapshot<V: View>(_ view: V, size: NSSize? = nil, dark: Bool, to url: URL) {
        // 屏幕外画图时窗口底色画不进去，自己垫一层底色，并把深浅色传给 SwiftUI。
        let host = NSHostingView(rootView: view
            .background(dark ? Color(white: 0.16) : Color(white: 0.96))
            .environment(\.colorScheme, dark ? .dark : .light))
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.appearance = appearance
        let fitting = size ?? host.fittingSize
        let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: fitting.width, height: fitting.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.backgroundColor = dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: fitting)
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        // 分栏视图有时要再排一轮版才稳定
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }

    /// 用真窗口截图（玻璃效果、按钮样式要窗口服务器画才看得到）：窗口放在屏幕外面，不抢前台。
    static func renderLive(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registerIconIfNeeded()
        isRendering = true
        let model = AppModel.shared
        prepareDemo(model)
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            for step in OnboardingView.Step.allCases {
                liveShot(OnboardingView(step: step) {}.environment(model), titled: true, dark: dark,
                         to: directory.appendingPathComponent("live-onboarding-\(step.rawValue)-\(suffix).png"))
            }
            model.cancelLearning()
            liveShot(MenuContentView().environment(model), titled: true, dark: dark,
                     to: directory.appendingPathComponent("live-panel-\(suffix).png"))
            for pane in SettingsPane.allCases where pane != .permissions {
                let navigation = SettingsNavigation()
                navigation.pane = pane
                liveShot(SettingsView().environment(model).environment(navigation).frame(width: 900, height: 680), titled: true, dark: dark,
                         to: directory.appendingPathComponent("live-settings-\(pane.rawValue)-\(suffix).png"))
            }
            let navigation = SettingsNavigation()
            navigation.pane = .permissions
            liveShot(SettingsView().environment(model).environment(navigation).frame(width: 900, height: 680), titled: true, dark: dark,
                     to: directory.appendingPathComponent("live-settings-permissions-\(suffix).png"))
            for (name, permission, granted) in [("drag", Permission.inputMonitoring, false), ("granted", .accessibility, true)] {
                let state = GuideState()
                state.permission = permission
                state.granted = granted
                liveShot(PermissionGuideView(state: state) {}.padding(20).background(dark ? Color(white: 0.2) : Color(white: 0.85)),
                         titled: true, dark: dark,
                         to: directory.appendingPathComponent("live-guide-\(name)-\(suffix).png"))
            }
        }
        exit(0)
    }

    private static func liveShot<V: View>(_ view: V, titled: Bool, dark: Bool, to url: URL) {
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: titled ? [.titled, .closable, .fullSizeContentView] : [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        if titled {
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                window.standardWindowButton(button)?.isHidden = true
            }
        } else {
            window.isOpaque = false
            window.backgroundColor = dark ? NSColor(white: 0.18, alpha: 1) : NSColor(white: 0.86, alpha: 1)
        }
        window.contentView = host
        window.orderFrontRegardless()
        window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l\(window.windowNumber)", url.path]
        try? capture.run()
        capture.waitUntilExit()
        window.orderOut(nil)
    }

    private static func registerIconIfNeeded() {
        // 用 swift run 直接跑时没有 App 包，图标从仓库里拿，登记成同名图片
        if NSImage(named: "VoxPalm") == nil {
            let icon = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("../../../brand/icon/VoxPalm.icns").standardized
            NSImage(contentsOf: icon)?.setName("VoxPalm")
        }
    }

    /// 用调试配置文件跑时，先选上媒体键、设好说话键，引导后几步和面板才有东西可画（不碰真正的设置）。
    private static func prepareDemo(_ model: AppModel) {
        guard ProcessInfo.processInfo.environment["VOXPALM_CONFIG"] != nil else { return }
        model.selectControlDevice(SystemKeysControlSource.mediaDeviceID)
        model.setBinding(KeyBinding(button: .media(16), buttonLabel: "播放 / 暂停（F8）", gesture: .long, action: .pushToTalk))
        model.simulate(transcript: "好的，收到，我下午看。", app: "微信", ago: 360)
        model.simulate(transcript: "下午三点的会改到四点，地点不变。", app: "备忘录", ago: 30)
    }

    static func renderUI(to directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        registerIconIfNeeded()
        isRendering = true
        let model = AppModel.shared
        prepareDemo(model)
        model.simulate(transcript: "下午三点的会改到四点，地点不变。")
        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            // 菜单栏图标：每个状态放大 4 倍
            let states: [MenuBarIconState] = [.idle, .armed, .listening, .transcribing, .paused, .attention]
            let strip = HStack(spacing: 18) {
                ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                    VStack(spacing: 6) {
                        Image(nsImage: MenuBarIcon.image(state, time: 0.3, level: 0.7)).resizable().frame(width: 72, height: 72)
                        Text(StatusItemController.label(state)).font(.caption)
                    }
                }
            }.padding(20)
            snapshot(strip, dark: dark, to: directory.appendingPathComponent("menubar-\(suffix).png"))
            // 面板：待命、正在听
            snapshot(MenuContentView().environment(model), dark: dark, to: directory.appendingPathComponent("panel-idle-\(suffix).png"))
            model.simulate(voiceState: .listening, level: 0.6)
            snapshot(MenuContentView().environment(model), dark: dark, to: directory.appendingPathComponent("panel-listening-\(suffix).png"))
            model.simulate(voiceState: .idle)
            // 说话浮窗的每个状态
            let hudStates: [(String, HUDState)] = [
                ("armed", .armed(since: Date().addingTimeInterval(-0.3), threshold: 0.5)), ("listening", .listening(since: Date().addingTimeInterval(-4), subtitle: "小米遥控器 2")),
                ("ime", .inputMethod(since: Date().addingTimeInterval(-2), subtitle: "小米遥控器 2")),
                ("transcribing", .transcribing), ("done", .done(characters: 15, app: "备忘录", snippet: "「下午三点的会改到四点，地…」")),
                ("short", .message(title: "按住超过 0.5 秒才算", subtitle: nil, tone: .muted)),
                ("error", .message(title: "没听到声音", subtitle: "看看麦克风开了没有，或者在面板里换一个", tone: .muted)),
                ("copied", .message(title: "字在剪贴板里，按 ⌘V", subtitle: "缺「辅助功能」权限，贴不到光标处", tone: .warn)),
            ]
            let board = VStack(alignment: .leading, spacing: 0) {
                ForEach(hudStates, id: \.0) { item in
                    let hud = HUDModel()
                    let _ = { hud.state = item.1; hud.level = 0.65 }()
                    SpeechHUDView(hud: hud)
                }
            }
            snapshot(board, dark: dark, to: directory.appendingPathComponent("hud-\(suffix).png"))
            // 设置各页
            for pane in SettingsPane.allCases {
                let navigation = SettingsNavigation()
                navigation.pane = pane
                snapshot(SettingsView().environment(model).environment(navigation), size: NSSize(width: 900, height: 680), dark: dark,
                         to: directory.appendingPathComponent("settings-\(pane.rawValue)-\(suffix).png"))
            }
            // 引导各步
            for step in OnboardingView.Step.allCases {
                snapshot(OnboardingView(step: step) {}.environment(model), dark: dark,
                         to: directory.appendingPathComponent("onboarding-\(step.rawValue)-\(suffix).png"))
            }
            model.cancelLearning()
            // 授权小窗：拖图标、麦克风开开关、打开以后
            let guides: [(String, Permission, Bool)] = [("drag", .inputMonitoring, false), ("mic", .microphone, false), ("granted", .accessibility, true)]
            for (name, permission, granted) in guides {
                let state = GuideState()
                state.permission = permission
                state.granted = granted
                snapshot(PermissionGuideView(state: state) {}, dark: dark,
                         to: directory.appendingPathComponent("guide-\(name)-\(suffix).png"))
            }
        }
        model.cancelLearning()
        exit(0)
    }
}
