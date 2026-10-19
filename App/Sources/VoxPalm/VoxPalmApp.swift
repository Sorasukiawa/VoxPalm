import AppKit
import SwiftUI
import VoxPalmVoice

/// 掌声只住在菜单栏：图标、面板、说话浮窗、设置和引导窗口都由 AppDelegate 用 AppKit 管。
/// 不用 SwiftUI 的 App 入口：只剩一个 Settings 场景时，系统会在启动时自己弹出一个空的设置窗口。
@main
enum VoxPalmMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.mainMenu = AppDelegate.mainMenu(target: delegate)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var status: StatusItemController?
    private var hud: SpeechHUDController?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private let navigation = SettingsNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivateModules.setUp()
        UIPreview.renderIfRequested()
        let model = AppModel.shared
        status = StatusItemController(model: model)
        hud = SpeechHUDController(model: model)
        model.openSettingsHandler = { [weak self] pane in self?.showSettings(pane) }
        model.openOnboardingHandler = { [weak self] in self?.showOnboarding() }
        model.closePanelHandler = { [weak self] in self?.status?.closePopover() }
        // 用调试配置文件跑的时候不弹引导。
        if !model.config.onboardingDone, ProcessInfo.processInfo.environment["VOXPALM_CONFIG"] == nil {
            showOnboarding()
        }
    }

    /// 退出前等控制设备收尾：接管了设备按键的来源要先让设备恢复普通按键。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppModel.shared.engine.shutdown {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 菜单栏 App 不显示主菜单，但 ⌘C / ⌘V / ⌘W / ⌘Q 这些快捷键要靠它才能在窗口和输入框里用。
    static func mainMenu(target: AppDelegate) -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String, _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            return item
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let menu = NSMenu(title: title)
            items.forEach(menu.addItem)
            let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            holder.submenu = menu
            return holder
        }
        let settings = item("设置…", #selector(AppDelegate.openSettingsFromMenu(_:)), ",")
        settings.target = target
        let main = NSMenu()
        main.addItem(submenu("掌声", [
            settings,
            .separator(),
            item("隐藏掌声", #selector(NSApplication.hide(_:)), "h"),
            item("退出掌声", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("编辑", [
            item("撤销", Selector(("undo:")), "z"),
            item("重做", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("剪切", #selector(NSText.cut(_:)), "x"),
            item("拷贝", #selector(NSText.copy(_:)), "c"),
            item("粘贴", #selector(NSText.paste(_:)), "v"),
            item("全选", #selector(NSText.selectAll(_:)), "a"),
        ]))
        main.addItem(submenu("窗口", [
            item("关闭", #selector(NSWindow.performClose(_:)), "w"),
            item("最小化", #selector(NSWindow.performMiniaturize(_:)), "m"),
        ]))
        return main
    }

    @objc func openSettingsFromMenu(_ sender: Any?) {
        showSettings(nil)
    }

    func showSettings(_ pane: SettingsPane?) {
        status?.closePopover()
        if let pane { navigation.pane = pane }
        if settingsWindow == nil {
            let host = NSHostingController(rootView: SettingsView().environment(AppModel.shared).environment(navigation))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "掌声设置"
            window.setContentSize(NSSize(width: 900, height: 680))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            Self.centerOnActiveScreen(window)
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showOnboarding() {
        status?.closePopover()
        // 每次打开都从第一步开始
        if onboardingWindow?.isVisible != true {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.tuckOnboardingIntoMenuBar() }
                .environment(AppModel.shared))
            let window = onboardingWindow ?? NSWindow(contentViewController: host)
            window.contentViewController = host
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "欢迎使用掌声"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
            Self.centerOnActiveScreen(window)
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// 窗口开在鼠标所在的那块屏幕正中（接了外接显示器时，`center()` 会放到别的屏幕上）。
    static func centerOnActiveScreen(_ window: NSWindow) {
        let mouse = NSEvent.mouseLocation
        guard let visible = (NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main)?.visibleFrame else {
            window.center()
            return
        }
        let size = window.frame.size
        // 和系统的 center() 一样略偏上一点
        window.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                      y: visible.midY - size.height / 2 + (visible.height - size.height) / 6))
    }

    /// 关掉引导窗口也一样收进菜单栏。
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender == onboardingWindow else { return true }
        AppModel.shared.cancelLearning()
        AppModel.shared.finishOnboarding()
        tuckOnboardingIntoMenuBar()
        return false
    }

    /// 引导结束：窗口缩小飞进菜单栏的掌声图标，图标弹一下，冒出「掌声在这儿」。
    /// 用窗口的截图来飞：直接缩真窗口会被 SwiftUI 的最小尺寸卡住。
    func tuckOnboardingIntoMenuBar() {
        guard let window = onboardingWindow else { return }
        let model = AppModel.shared
        let tip: String = {
            guard let key = model.talkKey else { return "点它看状态、换设备、改设置。" }
            let verb = key.gesture == .long ? "按住" : "按一下"
            return "点它看状态、换设备、改设置。现在\(verb)\(model.activeShortName ?? "设备")的「\(key.keyName)」，在任何 App 里说话就行。"
        }()
        let arrive = { [weak self] in
            self?.status?.celebrateArrival()
            self?.status?.showTip(tip, title: "掌声在这儿", seconds: 7)
        }
        guard let target = status?.iconFrameOnScreen, let content = window.contentView,
              let snapshot = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            window.orderOut(nil)
            arrive()
            return
        }
        content.cacheDisplay(in: content.bounds, to: snapshot)
        let image = NSImage(size: content.bounds.size)
        image.addRepresentation(snapshot)
        let start = window.frame
        let flyer = NSWindow(contentRect: start, styleMask: [.borderless], backing: .buffered, defer: false)
        flyer.isOpaque = false
        flyer.backgroundColor = .clear
        flyer.hasShadow = true
        flyer.level = .statusBar
        let imageView = NSImageView(image: image)
        imageView.imageScaling = .scaleAxesIndependently
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 16
        imageView.layer?.masksToBounds = true
        flyer.contentView = imageView
        flyer.orderFront(nil)
        window.orderOut(nil)
        let end = NSRect(x: target.midX - 18, y: target.midY - 13, width: 36, height: 26)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Motion.reduceMotion ? 0.15 : 0.62
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0, 0.25, 1)
            flyer.animator().setFrame(end, display: true)
            flyer.animator().alphaValue = 0.15
        }) {
            MainActor.assumeIsolated {
                flyer.orderOut(nil)
                arrive()
            }
        }
    }
}
