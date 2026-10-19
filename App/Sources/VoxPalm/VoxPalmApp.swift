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
final class AppDelegate: NSObject, NSApplicationDelegate {
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
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showOnboarding() {
        status?.closePopover()
        if onboardingWindow == nil {
            let host = NSHostingController(rootView: OnboardingView { [weak self] in self?.onboardingWindow?.close() }
                .environment(AppModel.shared))
            let window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.title = "欢迎使用掌声"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}
