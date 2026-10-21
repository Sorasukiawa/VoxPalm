import AppKit
import Observation
import os
import SwiftUI
import VoxPalmVoice

/// 点菜单栏图标、面板开关的诊断日志（`log show --predicate 'subsystem == "com.sorasukiawa.VoxPalm" && category == "panel"' --info`）
private let panelLog = Logger(subsystem: "com.sorasukiawa.VoxPalm", category: "panel")

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
    /// 面板正在收起（收起动画还没走完，这时 isShown 仍然是 true）
    private var closing = false
    /// 把面板关掉的那次按压（按在图标上，transient 面板一按下就收起）是什么时候按下的：这次按压松手时别再打开
    private var closingPress: TimeInterval?
    /// 收起动画还没走完时又点了图标：收完马上再打开
    private var reopenAfterClose = false

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
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
            return model.needsAttention ? .attention : .idle
        }
    }

    @objc private func clicked() {
        let event = NSApp.currentEvent
        panelLog.info("点图标：事件 \(Self.describe(event), privacy: .public)，面板\(self.popover.isShown ? (self.closing ? "正在收起" : "开着") : "关着", privacy: .public)，鼠标 \(Self.describe(NSEvent.mouseLocation), privacy: .public)，图标 \(self.iconFrameOnScreen.map(Self.describe) ?? "-", privacy: .public)")
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else if event?.modifierFlags.contains(.option) == true {
            model.setPaused(!model.isPaused)
            showTip(model.isPaused ? "已暂停监听 · 再按住 ⌥ 点一下继续" : "继续监听", seconds: 1.6)
        } else {
            toggle()
        }
    }

    /// 点图标：开着就关，关着就开。以前收起动画没走完时点一下会被当成「关」，看起来就是点了没反应。
    private func toggle() {
        // 面板是按在图标上的那一下关掉的：同一次按压松手时不再打开。macOS 27 起菜单栏图标由系统代管，
        // 这种按压的松手根本不转给掌声，以前「1 秒内的下一下都不算」会把紧接着真想打开的那一下吞掉；
        // 现在看系统记的最后一次按下鼠标的时刻，是同一次按压才不打开。
        if let press = closingPress {
            closingPress = nil
            if NSApp.currentEvent?.type == .leftMouseUp, let last = Self.lastMouseDown, abs(last - press) < 0.05 {
                panelLog.info("这一下是按下时把面板关掉的那次松手，不再打开")
                return
            }
        }
        // 面板还算开着、窗口却不在眼前（比如切到了别的桌面）：当成关着，在这里重新打开
        if popover.isShown, !closing, let window = popover.contentViewController?.view.window, !(window.isVisible && window.isOnActiveSpace) {
            popover.close()
        }
        if popover.isShown {
            if closing {
                // 正在收起时又点了：等这次收完马上再打开。直接 show 会被还没走完的那次收起冲掉
                reopenAfterClose = true
                popover.close()
            } else {
                popover.performClose(nil)
            }
            return
        }
        open()
    }

    private func open() {
        closing = false
        guard let button = item.button else { return }
        tip.performClose(nil)
        model.panelVisible = true
        Self.loadPanel(into: popover, model: model)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        let shown = popover.contentViewController
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, self.popover.contentViewController === shown else { return }
            let window = shown?.view.window
            panelLog.info("打开面板 0.4 秒后：\(self.popover.isShown ? "开着" : "已关", privacy: .public)，窗口 \(window.map { Self.describe($0.frame) } ?? "-", privacy: .public) 在 \(window?.screen?.localizedName ?? "-", privacy: .public)，可见 \(window?.isVisible == true, privacy: .public)，在当前桌面 \(window?.isOnActiveSpace == true, privacy: .public)，没被挡住 \(window?.occlusionState.contains(.visible) == true, privacy: .public)")
        }
    }

    func popoverWillClose(_ notification: Notification) {
        panelLog.info("面板收起：鼠标\(NSEvent.pressedMouseButtons & 1 != 0 ? "按着" : "松着", privacy: .public) \(Self.describe(NSEvent.mouseLocation), privacy: .public)，原因 \(String(describing: notification.userInfo?[NSPopover.closeReasonUserInfoKey] ?? "-"), privacy: .public)")
        closing = true
        if NSEvent.pressedMouseButtons & 1 != 0, let frame = iconFrameOnScreen, frame.contains(NSEvent.mouseLocation) {
            closingPress = Self.lastMouseDown
        }
    }

    func popoverDidClose(_ notification: Notification) {
        panelLog.info("面板收完\(self.reopenAfterClose ? "，马上再打开" : "", privacy: .public)")
        closing = false
        model.panelVisible = false
        // 关上就扔掉面板内容：SwiftUI 的动画（说话时的声波、计时）在收起来的窗口里也照样每秒画几十帧
        popover.contentViewController = nil
        if reopenAfterClose {
            reopenAfterClose = false
            DispatchQueue.main.async { [weak self] in self?.open() }
        }
    }

    /// 系统记的最后一次按下鼠标左键的时刻（开机以来的秒数）
    private static var lastMouseDown: TimeInterval? {
        let ago = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
        return ago.isFinite && ago >= 0 ? ProcessInfo.processInfo.systemUptime - ago : nil
    }

    /// 换一份新的面板：每次打开都换，磁贴收起、里面的几块依次浮上来。先排好版、定好大小再弹出，免得先小后大。
    static func loadPanel(into popover: NSPopover, model: AppModel) {
        let host = NSHostingController(rootView: MenuContentView().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.contentSize = host.view.fittingSize
    }

    func closePopover() {
        reopenAfterClose = false
        popover.performClose(nil)
    }

    func showPopover() {
        guard !popover.isShown || closing else { return }
        toggle()
    }

    // MARK: - 右键菜单

    private func showMenu() {
        closePopover()
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
    /// 音量不用盯：说话时计时器每一帧都按当时的音量画（以前音量一变就多画一次，说话时每秒画 40 次）。
    private func observe() {
        withObservationTracking {
            _ = state
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
        let image = MenuBarIcon.image(state, time: Date().timeIntervalSince(started), level: model.micLevel, progress: progress, flash: flash)
        // 和上一帧一个像素都不差就不换：每换一次图标，系统都要给每块屏幕的菜单栏重新截一张、再跨进程送过去，
        // 说话时这是主线程上最大的一块开销；而说话时图标只跟着音量变，很多帧和上一帧完全一样
        let pixels = Self.pixels(of: image)
        if let pixels, pixels == lastPixels { return }
        lastPixels = pixels
        item.button?.image = image
    }

    /// 上一帧图标画出来的像素
    private var lastPixels: Data?

    /// 把图标画成 36 × 36 像素（菜单栏上 2 倍图的大小），用来比较两帧是不是一样
    private static func pixels(of image: NSImage) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: 36, height: 36))
        NSGraphicsContext.restoreGraphicsState()
        guard let bytes = rep.bitmapData else { return nil }
        // 模板图和彩色图像素一样也不能当成同一帧（系统给模板图上色）
        return Data([image.isTemplate ? 1 : 0]) + Data(bytes: bytes, count: rep.bytesPerRow * rep.pixelsHigh)
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

    private static func describe(_ event: NSEvent?) -> String {
        guard let event else { return "无" }
        return "\(event.type.rawValue) 窗口 \(event.windowNumber) 修饰键 \(event.modifierFlags.intersection(.deviceIndependentFlagsMask).rawValue)"
    }

    private static func describe(_ point: NSPoint) -> String { "(\(Int(point.x)), \(Int(point.y)))" }
    private static func describe(_ rect: NSRect) -> String { "(\(Int(rect.minX)), \(Int(rect.minY)), \(Int(rect.width))×\(Int(rect.height)))" }

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
