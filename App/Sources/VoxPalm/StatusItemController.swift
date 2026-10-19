import AppKit
import Observation
import SwiftUI
import VoxPalmVoice

/// 菜单栏的掌声图标和点开的面板。直接用 NSStatusItem（不用 MenuBarExtra），才能画带颜色、会动的图标。
/// 点一下开面板；右键是快捷菜单；按住 ⌥ 点一下直接暂停 / 继续监听。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let tip = NSPopover()
    private let model: AppModel
    private var animation: Timer?
    private let started = Date()
    private var tipWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        Self.loadPanel(into: popover, model: model)
        tip.behavior = .transient
        tip.animates = true
        refresh()
        observe()
    }

    var state: MenuBarIconState {
        switch model.voiceState {
        case .armed: return .armed
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .idle:
            if model.isPaused { return .paused }
            return model.attentions.isEmpty ? .idle : .attention
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            model.setPaused(!model.isPaused)
            showTip(model.isPaused ? "已暂停监听 · 再按住 ⌥ 点一下继续" : "继续监听", seconds: 1.6)
        } else {
            toggle()
        }
    }

    private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            tip.performClose(nil)
            Self.loadPanel(into: popover, model: model)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    /// 换一份新的面板：每次打开都换，磁贴收起、里面的几块依次浮上来。先排好版、定好大小再弹出，免得先小后大。
    static func loadPanel(into popover: NSPopover, model: AppModel) {
        let host = NSHostingController(rootView: MenuContentView().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
    }

    func closePopover() { popover.performClose(nil) }

    func showPopover() {
        guard !popover.isShown else { return }
        toggle()
    }

    // MARK: - 右键菜单

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        // 第一行写现在的状态（不能点），和面板右上角的标签一致
        let header = NSMenuItem(title: "掌声 · \(Self.label(state))", action: nil, keyEquivalent: "")
        header.isEnabled = false
        header.image = Self.symbol("circle.fill", color: stateColor)
        menu.addItem(header)
        menu.addItem(.separator())
        let pause = NSMenuItem(title: model.isPaused ? "继续监听" : "暂停监听", action: #selector(menuPause), keyEquivalent: "")
        pause.target = self
        pause.image = Self.symbol(model.isPaused ? "play.circle" : "pause.circle")
        pause.toolTip = "按住 ⌥ 点图标也可以"
        menu.addItem(pause)
        let settings = NSMenuItem(title: "设置…", action: #selector(menuSettings), keyEquivalent: ",")
        settings.target = self
        settings.image = Self.symbol("gearshape")
        menu.addItem(settings)
        let onboarding = NSMenuItem(title: "重新打开引导", action: #selector(menuOnboarding), keyEquivalent: "")
        onboarding.target = self
        onboarding.image = Self.symbol("sparkles")
        menu.addItem(onboarding)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出掌声", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = Self.symbol("power")
        menu.addItem(quit)
        if let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        }
    }

    private var stateColor: NSColor {
        switch state {
        case .armed, .listening: return NSColor(Brand.coralBottom)
        case .transcribing: return NSColor(Brand.lavender)
        case .attention: return .systemOrange
        case .idle: return .systemGreen
        case .paused: return .secondaryLabelColor
        }
    }

    /// 菜单项前面的小图标（SF Symbol）；给了颜色就画成彩色，否则跟着菜单的文字色
    private static func symbol(_ name: String, color: NSColor? = nil) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        guard let color else { return image }
        let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold).applying(.init(paletteColors: [color]))
        let colored = image.withSymbolConfiguration(config)
        colored?.isTemplate = false
        return colored
    }

    @objc private func menuPause() { model.setPaused(!model.isPaused) }
    @objc private func menuSettings() { model.openSettings() }
    @objc private func menuOnboarding() { model.openOnboarding() }

    // MARK: - 提示气泡、到达动画

    /// 图标下面冒一句话，过几秒自己收起（暂停提示、引导结束后的「掌声在这儿」）。
    func showTip(_ text: String, title: String? = nil, seconds: Double) {
        guard let button = item.button else { return }
        tipWork?.cancel()
        let symbol = title != nil ? nil : (model.isPaused ? "pause.circle.fill" : "play.circle.fill")
        tip.contentViewController = NSHostingController(rootView: TipView(title: title, text: text, symbol: symbol))
        if !tip.isShown { tip.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        let work = DispatchWorkItem { [weak self] in self?.tip.performClose(nil) }
        tipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// 引导窗口飞进来以后，图标弹一下、亮一圈。
    func celebrateArrival() {
        guard let button = item.button, !Motion.reduceMotion else { return }
        button.wantsLayer = true
        guard let layer = button.layer else { return }
        layer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        layer.position = CGPoint(x: button.frame.midX, y: button.frame.midY)
        let bounce = CAKeyframeAnimation(keyPath: "transform.scale")
        bounce.values = [0.4, 1.28, 0.92, 1.0]
        bounce.keyTimes = [0, 0.45, 0.75, 1]
        bounce.duration = 0.6
        bounce.timingFunctions = [CAMediaTimingFunction(name: .easeOut), CAMediaTimingFunction(name: .easeInEaseOut), CAMediaTimingFunction(name: .easeOut)]
        layer.add(bounce, forKey: "arrive")
    }

    /// 图标在屏幕上的位置（引导窗口往这里飞）
    var iconFrameOnScreen: NSRect? {
        guard let button = item.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    // MARK: - 画图标

    /// 状态变了就重画；会动的状态开一个计时器（每秒约 20 帧），不动的时候不占 CPU。
    private func observe() {
        withObservationTracking {
            _ = state
            _ = model.micLevel
            _ = model.lastInsertedAt
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
                self?.observe()
            }
        }
    }

    /// 出完字后 1 秒内两行字刷一下
    private var flash: Double {
        guard let at = model.lastInsertedAt else { return 1 }
        return min(1, Date().timeIntervalSince(at) / 1.0)
    }

    private var progress: Double {
        guard state == .armed, let since = model.talkStartedAt else { return 0 }
        return Date().timeIntervalSince(since) / max(0.05, model.config.timing.longPressThreshold)
    }

    private func draw() {
        item.button?.image = MenuBarIcon.image(state, time: Date().timeIntervalSince(started), level: model.micLevel, progress: progress, flash: flash)
    }

    private func refresh() {
        let current = state
        draw()
        item.button?.setAccessibilityLabel("掌声：" + Self.label(current))
        let animated = current.isAnimated || flash < 1
        if animated, animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.draw()
                    if !self.state.isAnimated && self.flash >= 1 {
                        self.animation?.invalidate()
                        self.animation = nil
                    }
                }
            }
        } else if !animated {
            animation?.invalidate()
            animation = nil
        }
    }

    static func label(_ state: MenuBarIconState) -> String {
        switch state {
        case .idle: return "待命"
        case .armed: return "准备中"
        case .listening: return "正在听"
        case .transcribing: return "转写中"
        case .paused: return "已暂停"
        case .attention: return "要处理"
        }
    }
}

/// 图标下面的提示气泡：有标题时（引导结束的「掌声在这儿」）左边是会动的 Logo，否则是一个小图标加一句话。
struct TipView: View {
    let title: String?
    let text: String
    var symbol: String?

    var body: some View {
        HStack(alignment: title == nil ? .center : .top, spacing: 11) {
            if title != nil {
                LogoMark(size: 40, interactive: false)
            } else if let symbol {
                Image(systemName: symbol).font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white, Brand.coralBottom)
                    .symbolRenderingMode(.palette)
            }
            VStack(alignment: .leading, spacing: 3) {
                if let title { Text(title).font(.headline) }
                Text(text).font(.callout).foregroundStyle(title == nil ? .primary : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: title == nil ? nil : 280, alignment: .leading)
        .fixedSize(horizontal: title == nil, vertical: true)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(BrandBackdrop(opaque: false))
    }
}
