import AppKit
import Observation
import SwiftUI
import VoxPalmVoice

/// 菜单栏的掌声图标和点开的面板。直接用 NSStatusItem（不用 MenuBarExtra），才能画带颜色、会动的图标。
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    private var animation: Timer?
    private let started = Date()

    init(model: AppModel) {
        self.model = model
        super.init()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: MenuContentView().environment(model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
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

    @objc private func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = item.button {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func closePopover() { popover.performClose(nil) }

    /// 状态变了就重画；会动的状态开一个计时器（每秒约 15 帧），不动的时候不占 CPU。
    private func observe() {
        withObservationTracking {
            _ = state
            _ = model.micLevel
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.refresh()
                self?.observe()
            }
        }
    }

    private func refresh() {
        let current = state
        item.button?.image = MenuBarIcon.image(current, time: Date().timeIntervalSince(started), level: model.micLevel)
        item.button?.setAccessibilityLabel("掌声：" + Self.label(current))
        if current.isAnimated, animation == nil {
            animation = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.item.button?.image = MenuBarIcon.image(self.state, time: Date().timeIntervalSince(self.started), level: self.model.micLevel)
                }
            }
        } else if !current.isAnimated {
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
