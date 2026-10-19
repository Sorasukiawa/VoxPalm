import AppKit
import Observation
import SwiftUI

/// 授权小窗：打开系统设置对应的隐私页，在系统设置窗口下面浮出掌声的图标，
/// 把它拖进列表就行（Codex、Claude 也是这么做的）。小窗跟着系统设置窗口走，
/// 系统设置不在前台时先藏起来，权限打开后打个勾、自己收起，再把掌声切回前台。
/// 麦克风的列表不能拖进去，小窗只提示打开开关。
@MainActor
final class PermissionGuide {
    static let shared = PermissionGuide()

    private let state = GuideState()
    private var panel: NSPanel?
    private var timer: Timer?
    private var startedAt = Date()
    private var lastSeenSettings = Date()
    private var grantedAt: Date?

    private static let settingsBundleID = "com.apple.systempreferences"
    private static let size = NSSize(width: 460, height: 132)

    func start(_ permission: Permission) {
        state.permission = permission
        state.granted = false
        grantedAt = nil
        startedAt = Date()
        lastSeenSettings = Date()
        NSWorkspace.shared.open(permission.settingsURL)
        if panel == nil { panel = makePanel() }
        panel?.alphaValue = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.2; panel.animator().alphaValue = 0 }) {
            MainActor.assumeIsolated { panel.orderOut(nil) }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = NSHostingView(rootView: PermissionGuideView(state: state) { [weak self] in self?.stop() })
        return panel
    }

    private func tick() {
        guard let panel else { return }
        if !state.granted, state.permission.isGranted {
            state.granted = true
            grantedAt = Date()
            AppModel.shared.refreshPermissions()
        }
        if let grantedAt, Date().timeIntervalSince(grantedAt) > 1.4 {
            stop()
            NSApp.activate()
            return
        }

        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        guard let frame = Self.settingsWindowFrame() else {
            // 系统设置还没出来就再等等；出来过又关掉了，小窗跟着收起。
            if Date().timeIntervalSince(lastSeenSettings) > (panel.isVisible ? 1 : 8) { stop() }
            return
        }
        lastSeenSettings = Date()
        // 只在系统设置在前台时露面，切到别的 App 就先藏起来
        if front != Self.settingsBundleID {
            if panel.isVisible { panel.orderOut(nil) }
            return
        }
        let target = Self.placement(for: frame)
        if !panel.isVisible {
            // 从系统设置窗口下沿往上浮出来
            panel.setFrame(target.offsetBy(dx: 0, dy: -14), display: false)
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.28
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
                panel.animator().setFrame(target, display: true)
            }
        } else if panel.frame.origin != target.origin {
            panel.setFrame(target, display: true)
        }
    }

    /// 放在系统设置右半边（列表那一栏）的正下方；下面没地方就压在窗口底部里面。
    private static func placement(for settings: NSRect) -> NSRect {
        let sidebar: CGFloat = settings.width > 640 ? 215 : 0
        let centerX = settings.minX + sidebar + (settings.width - sidebar) / 2
        var origin = NSPoint(x: centerX - size.width / 2, y: settings.minY - size.height + 6)
        let screen = NSScreen.screens.first { $0.frame.intersects(settings) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            if origin.y < visible.minY + 8 { origin.y = settings.minY + 16 }
            origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        }
        return NSRect(origin: origin, size: size)
    }

    /// 系统设置最前面那个窗口的位置（转成 AppKit 坐标：原点在主屏左下角）。窗口位置不用录屏权限也读得到。
    private static func settingsWindowFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: settingsBundleID).first else { return nil }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for info in windows {
            guard info[kCGWindowOwnerPID as String] as? pid_t == app.processIdentifier,
                  info[kCGWindowLayer as String] as? Int == 0,
                  let bounds = info[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: bounds as! CFDictionary),
                  rect.width > 300, rect.height > 200 else { continue }
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            return NSRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
}

@MainActor
@Observable
final class GuideState {
    var permission: Permission = .accessibility
    var granted = false
}

struct PermissionGuideView: View {
    let state: GuideState
    let close: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            if state.granted {
                ZStack {
                    Circle().fill(Color.tileGreen).frame(width: 54, height: 54)
                    Image(systemName: "checkmark").font(.system(size: 24, weight: .bold)).foregroundStyle(.white)
                }
                .transition(.scale.combined(with: .opacity))
                VStack(alignment: .leading, spacing: 3) {
                    Text("「\(state.permission.title)」已开启").font(.headline)
                    Text("回到掌声继续…").font(.callout).foregroundStyle(.secondary)
                }
            } else if state.permission.supportsDrag {
                DraggableAppIcon()
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up").font(.headline.weight(.bold)).foregroundStyle(Brand.coralText)
                        Text("把「掌声」拖到上面的列表里").font(.headline)
                    }
                    Text("系统会要你输入密码或按指纹。已经在列表里的话，直接打开它旁边的开关。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                IconTile(symbol: state.permission.symbol, color: state.permission.tileColor, size: 54)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up").font(.headline.weight(.bold)).foregroundStyle(Brand.coralText)
                        Text("在上面的列表里打开「掌声」的开关").font(.headline)
                    }
                    Text("打开后回到掌声就能用。")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 30)
        .frame(width: 440, height: 104)
        .floatingGlass(cornerRadius: 24)
        .overlay(alignment: .topTrailing) {
            if !state.granted {
                Button(action: close) {
                    Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .padding(10)
                .help("不用了")
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
        .frame(width: 460, height: 132)
        .animation(.spring(duration: 0.35), value: state.granted)
    }
}

/// 可以拖走的掌声图标：拖出去的是 App 本身（文件），系统设置的列表收到就会把它加进去。
struct DraggableAppIcon: View {
    @State private var bob = false

    var body: some View {
        AppIconImage(size: 58)
            .shadow(color: Brand.coralBottom.opacity(0.35), radius: 8, y: 3)
            .offset(y: bob ? -3 : 1)
            .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: bob)
            .overlay(AppDragSource())
            .onAppear { bob = true }
            .help("按住拖到上面的列表里")
    }
}

private struct AppDragSource: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSourceView { DragSourceView() }
    func updateNSView(_ nsView: DragSourceView, context: Context) {}

    final class DragSourceView: NSView, NSDraggingSource {
        private var downEvent: NSEvent?

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func mouseDown(with event: NSEvent) { downEvent = event }

        override func mouseDragged(with event: NSEvent) {
            guard let downEvent else { return }
            self.downEvent = nil
            let url = Bundle.main.bundleURL
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            icon.size = NSSize(width: 64, height: 64)
            item.setDraggingFrame(NSRect(x: bounds.midX - 32, y: bounds.midY - 32, width: 64, height: 64), contents: icon)
            beginDraggingSession(with: [item], event: downEvent, source: self)
        }

        func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
            context == .outsideApplication ? [.copy, .link, .generic] : []
        }
    }
}
