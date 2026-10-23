import AppKit
import SwiftUI
import VoxPalmVoice

/// 掌声只住在菜单栏：图标、面板、说话浮窗、设置和引导窗口都由 AppDelegate 用 AppKit 管。
/// 不用 SwiftUI 的 App 入口：只剩一个 Settings 场景时，系统会在启动时自己弹出一个空的设置窗口。
@main
enum VoxPalmMain {
    @MainActor
    static func main() {
        // Objective-C 异常默认被 AppKit 的事件循环接住、程序接着跑。异常一旦穿过 Swift 代码（尤其是 MainActor 的 Task），
        // 并发运行时记的「当前任务、当前执行器」就停在作废的栈上，之后在不相干的 MainActor.assumeIsolated 里崩
        // （2026-10-20 测试包：装收音 tap 时格式对不上抛了异常，43 秒后崩在权限定时器里）。改成在抛出的地方直接崩，崩溃报告里就是真正的原因。
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
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
    private let launchedAt = Date()

    func applicationDidFinishLaunching(_ notification: Notification) {
        PrivateModules.setUp()
        UIPreview.renderIfRequested()
        let model = AppModel.shared
        status = StatusItemController(model: model)
        hud = SpeechHUDController(model: model)
        model.openSettingsHandler = { [weak self] pane in self?.showSettings(pane) }
        model.openOnboardingHandler = { [weak self] in self?.showOnboarding() }
        model.closePanelHandler = { [weak self] in self?.status?.closePopover() }
        // 用调试配置文件跑的时候不弹引导；带 --onboarding 启动时直接打开引导（open VoxPalm.app --args --onboarding）。
        if CommandLine.arguments.contains("--onboarding")
            || (!model.config.onboardingDone && ProcessInfo.processInfo.environment["VOXPALM_CONFIG"] == nil) {
            showOnboarding()
        }
    }

    /// 系统在启动时、以及在访达里再次打开掌声时会发「重新打开」，默认处理会去点主菜单的「设置…」弹出设置窗口。
    /// 启动时那次不管；之后再次打开掌声时弹出菜单栏面板，告诉用户掌声在哪。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, Date().timeIntervalSince(launchedAt) > 2 { status?.showPopover() }
        return false
    }

    /// 退出前等控制设备收尾：接管了设备按键的来源要先让设备恢复普通按键。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        do {
            try AppModel.shared.flushConfig()
        } catch {
            let alert = NSAlert()
            alert.messageText = "设置还没有保存"
            alert.informativeText = "\(error.localizedDescription)\n\n现在退出会丢掉本次未保存的修改。可以返回设置导出备份。"
            alert.addButton(withTitle: "返回检查")
            alert.addButton(withTitle: "仍然退出")
            guard alert.runModal() == .alertSecondButtonReturn else {
                showSettings(.about)
                return .terminateCancel
            }
        }
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
            Self.useInsetTitlebar(window)
            window.setContentSize(NSSize(width: 900, height: 680))
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.delegate = self
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

    /// 设置窗口的标题栏加高（空的工具栏）：左上角三个按钮往下挪，落在浮起来的边栏里面，和系统设置一样。
    static func useInsetTitlebar(_ window: NSWindow) {
        window.toolbar = NSToolbar(identifier: "settings")
        window.toolbarStyle = .unified
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

    /// 关掉设置窗口就连里面的内容一起扔掉，下次打开重新建（还停在关掉时那一页）。
    /// SwiftUI 的循环动画（Pro 页的小动画、授权页的拖拽示意）在关掉、收起来的窗口里也照样每秒画几十帧。
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        settingsWindow = nil
        DispatchQueue.main.async { window.contentViewController = nil }
    }

    /// 引导收进菜单栏以后扔掉窗口和里面的内容（理由同上），下次「重新打开引导」重新建。
    private func releaseOnboarding(_ window: NSWindow) {
        window.orderOut(nil)
        window.contentViewController = nil
        if onboardingWindow === window { onboardingWindow = nil }
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
            releaseOnboarding(window)
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
        releaseOnboarding(window)
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
