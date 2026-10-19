import AppKit
import Observation
import SwiftUI
import VoxPalmVoice

/// 说话浮窗的状态（design/README.md「状态」和设计稿「说话浮窗」一节）。
enum HUDState: Equatable {
    case hidden
    /// 按下了，还没满长按时间
    case armed(since: Date)
    case listening(since: Date, subtitle: String)
    /// 外部输入法模式：替用户按住了输入法的语音键
    case inputMethod(since: Date, subtitle: String)
    case transcribing
    case done(characters: Int, app: String?)
    case handedOff
    case short(threshold: Double)
    case error(title: String, subtitle: String)

    var dotColor: Color {
        switch self {
        case .hidden, .armed, .listening, .inputMethod: return Brand.coralTop
        case .transcribing: return HUDColors.lavender
        case .done, .handedOff: return HUDColors.ok
        case .short: return HUDColors.fg2
        case .error: return HUDColors.err
        }
    }

    var since: Date? {
        switch self {
        case let .armed(since), let .listening(since, _), let .inputMethod(since, _): return since
        default: return nil
        }
    }
}

enum HUDColors {
    static let background = Color(red: 23 / 255, green: 21 / 255, blue: 31 / 255).opacity(0.9)
    static let line = Color(red: 1, green: 243 / 255, blue: 234 / 255).opacity(0.08)
    static let fg = Color(red: 1, green: 243 / 255, blue: 234 / 255)
    static let fg2 = Color(red: 1, green: 243 / 255, blue: 234 / 255).opacity(0.62)
    static let ok = Color(red: 0x5D / 255, green: 0xD3 / 255, blue: 0x9A / 255)
    static let err = Color(red: 1, green: 0x7A / 255, blue: 0x6E / 255)
    static let lavender = Color(red: 0xB3 / 255, green: 0xAD / 255, blue: 0xE6 / 255)
    static let coralDeep = Color(red: 0xA9 / 255, green: 0x3F / 255, blue: 0x1C / 255)
}

@MainActor
@Observable
final class HUDModel {
    var state: HUDState = .hidden
    var level: Float = 0
}

/// 浮窗本体：屏幕下方正中、程序坞上面，不抢焦点、不接收点击，所有桌面和全屏 App 上都能看到。
@MainActor
final class SpeechHUDController {
    let hud = HUDModel()
    private let model: AppModel
    private let panel: NSPanel
    private let host: NSHostingView<AnyView>
    private var hideWork: DispatchWorkItem?
    private var armedWork: DispatchWorkItem?

    init(model: AppModel) {
        self.model = model
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: Self.canvas),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.ignoresMouseEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        host = NSHostingView(rootView: AnyView(EmptyView()))
        // 画布固定大小、胶囊贴底居中：状态一变胶囊自己伸缩，不用等 SwiftUI 排完版再改窗口大小。
        host.rootView = AnyView(SpeechHUDView(hud: hud).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom))
        panel.contentView = host

        model.onVoiceStateChange = { [weak self] state in self?.voiceStateChanged(state) }
        model.onVoiceOutcome = { [weak self] outcome in self?.outcome(outcome) }
        observeLevel()
    }

    private func observeLevel() {
        withObservationTracking { _ = model.micLevel } onChange: { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hud.level = self.model.micLevel
                self.observeLevel()
            }
        }
    }

    private var subtitle: String {
        let control = model.activeDevice?.name ?? "按键"
        let mic = model.selectedMic?.name ?? "系统默认输入"
        return "\(control) · \(mic)"
    }

    private func voiceStateChanged(_ state: VoiceSession.State) {
        switch state {
        case .armed:
            // 短按（单击）会马上放弃预录，晚 0.15 秒再出浮窗，免得一闪而过。
            let since = model.talkStartedAt ?? Date()
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.voiceState == .armed else { return }
                self.show(.armed(since: since))
            }
            armedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        case .listening:
            armedWork?.cancel()
            let since = model.talkStartedAt ?? Date()
            if model.config.voice.mode == .inputMethod {
                let mic = model.selectedMic.map { " · 麦克风临时切到 \($0.name)" } ?? ""
                show(.inputMethod(since: since, subtitle: "已替你按住 \(model.config.voice.inputMethodKey.key.title)\(mic)"))
            } else {
                show(.listening(since: since, subtitle: subtitle))
            }
        case .transcribing:
            show(.transcribing)
        case .idle:
            armedWork?.cancel()
            // 没有结果要说（安静地放弃了预录）就收起来；有结果的话 outcome 会接着显示。
            if case .armed = hud.state { hide(after: 0) }
            if case .listening = hud.state { hide(after: 0.4) }
        }
    }

    private func outcome(_ outcome: VoiceSession.Outcome) {
        switch outcome {
        case let .inserted(count, app):
            show(.done(characters: count, app: app), hideAfter: 1.5)
        case .handedToInputMethod:
            show(.handedOff, hideAfter: 1.5)
        case let .copied(count):
            show(.error(title: "字没贴进去", subtitle: "缺「辅助功能」权限，\(count) 个字已经拷贝，按 ⌘V 粘贴"), hideAfter: 4)
        case let .tooShort(threshold):
            show(.short(threshold: threshold), hideAfter: 1.8)
        case .noAudio:
            show(.error(title: "没听到声音", subtitle: "看看无线麦开了没有，或者换个收音设备"), hideAfter: 4)
        case .noText:
            show(.error(title: "没听出字", subtitle: "再说一次，离麦克风近一点"), hideAfter: 4)
        case let .failed(message):
            show(.error(title: "转写出错", subtitle: String(message.prefix(40))), hideAfter: 4)
        }
    }

    func show(_ state: HUDState, hideAfter delay: Double? = nil) {
        hideWork?.cancel()
        withAnimation(.easeOut(duration: 0.18)) { hud.state = state }
        layout()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.18; panel.animator().alphaValue = 1 }
        }
        if let delay { hide(after: delay) }
    }

    private func hide(after delay: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.panel.animator().alphaValue = 0 }) {
                MainActor.assumeIsolated {
                    self.panel.orderOut(nil)
                    self.hud.state = .hidden
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 透明画布的大小，比最长的一条提示宽；浮窗不接鼠标，空白处不挡操作。
    private static let canvas = NSSize(width: 760, height: 130)

    /// 放在鼠标所在屏幕的下方正中、程序坞上面。
    private func layout() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.midX - Self.canvas.width / 2, y: visible.minY - 2,
                              width: Self.canvas.width, height: Self.canvas.height), display: false)
    }
}

/// 深色半透明胶囊：● → 声波 / 三行字 → 标题副标题 → 计时。深浅色模式下都一样。
struct SpeechHUDView: View {
    let hud: HUDModel

    var body: some View {
        HStack(spacing: 12) {
            HUDDot(state: hud.state)
            if showsSignal {
                HUDSignal(state: hud.state, level: hud.level)
                    .frame(width: 58, height: 28)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 14.5, weight: .semibold)).foregroundStyle(HUDColors.fg).lineLimit(1)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(HUDColors.fg2).lineLimit(1)
                }
            }
            .fixedSize()
            if let since = hud.state.since {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.clock(context.date.timeIntervalSince(since)))
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(HUDColors.fg2)
                }
                .padding(.leading, 2)
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 18)
        .padding(.vertical, 9)
        .frame(minHeight: 52)
        .background(Capsule().fill(HUDColors.background).shadow(color: .black.opacity(0.35), radius: 14, y: 6))
        .overlay(Capsule().stroke(HUDColors.line, lineWidth: 1))
        // 阴影往下偏，底下多留一些，免得被窗口边切掉
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 40)
        .fixedSize()
    }

    private var showsSignal: Bool {
        switch hud.state {
        case .short, .error, .hidden: return false
        default: return true
        }
    }

    private var title: String {
        switch hud.state {
        case .hidden: return ""
        case .armed: return "准备中"
        case .listening: return "正在听"
        case .inputMethod: return "输入法在听"
        case .transcribing: return "正在转文字"
        case let .done(count, _): return "已输入 \(count) 字"
        case .handedOff: return "交给输入法了"
        case .short: return "按得太短，没算数"
        case let .error(title, _): return title
        }
    }

    private var subtitle: String? {
        switch hud.state {
        case .hidden: return nil
        case .armed: return "已经在录，按住别松"
        case let .listening(_, subtitle), let .inputMethod(_, subtitle): return subtitle
        case .transcribing: return "在这台 Mac 上处理"
        case let .done(_, app): return app.map { "贴到了「\($0)」的光标处" } ?? "贴到了光标处"
        case .handedOff: return "字由输入法放进去"
        case let .short(threshold): return String(format: "按住超过 %.2f 秒才开始说话", threshold)
        case let .error(_, subtitle): return subtitle
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 左边的 ●：录音时珊瑚色带厚度，准备中一跳一跳，正在听时外圈一圈圈扩散。
struct HUDDot: View {
    let state: HUDState

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if case .listening = state { ring(t) }
                if case .inputMethod = state { ring(t) }
                Circle()
                    .fill(isCoral ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(state.dotColor))
                    .shadow(color: isCoral ? HUDColors.coralDeep : .clear, radius: 0, y: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse(t))
            }
            .frame(width: 24, height: 24)
        }
    }

    private var isCoral: Bool {
        switch state {
        case .armed, .listening, .inputMethod: return true
        default: return false
        }
    }

    private func pulse(_ t: Double) -> CGFloat {
        guard case .armed = state else { return 1 }
        return 0.72 + 0.28 * (0.5 + 0.5 * cos(2 * .pi * t / 0.8))
    }

    private func ring(_ t: Double) -> some View {
        let p = (t.truncatingRemainder(dividingBy: 1.3)) / 1.3
        return Circle()
            .stroke(Brand.coralTop.opacity(1 - p), lineWidth: 2)
            .frame(width: 14 + 10 * p, height: 14 + 10 * p)
    }
}

/// 中间的信号区：录音时 7 根竖条跟着音量跳，转写时收成三行字一行行填满，出字后停住并亮一个光标。
struct HUDSignal: View {
    let state: HUDState
    let level: Float

    private static let shape: [Double] = [0.35, 0.7, 1, 0.55, 0.85, 0.45, 0.25]

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                switch state {
                case .armed, .listening, .inputMethod:
                    let count = Self.shape.count
                    let gap = (size.width - 4 * Double(count)) / Double(count - 1)
                    for index in 0..<count {
                        let scale: Double
                        if case .armed = state {
                            scale = 0.28
                        } else {
                            // 音量决定整体高度，每根加一点各自的起伏
                            let wobble = 0.75 + 0.25 * sin(t * 9 + Double(index) * 1.7)
                            scale = max(0.18, min(1, Self.shape[index] * (0.25 + 1.1 * Double(level)) * wobble))
                        }
                        let h = 26 * scale
                        let rect = CGRect(x: Double(index) * (4 + gap), y: (size.height - h) / 2, width: 4, height: h)
                        canvas.fill(Path(roundedRect: rect, cornerRadius: 2),
                                    with: .linearGradient(Gradient(colors: [Brand.coralTop, Brand.coralBottom]),
                                                          startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                    }
                case .transcribing, .done, .handedOff:
                    let widths = [1.0, 0.78, 0.46]
                    let top = (size.height - (3 * 4 + 2 * 5)) / 2
                    for (index, width) in widths.enumerated() {
                        var fill = 1.0
                        if case .transcribing = state {
                            let p = ((t - Double(index) * 0.15).truncatingRemainder(dividingBy: 1)) / 1
                            fill = p < 0 ? p + 1 : p
                        }
                        let rect = CGRect(x: 0, y: top + Double(index) * 9, width: size.width * width * fill, height: 4)
                        canvas.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(HUDColors.fg.opacity(state == .transcribing ? 0.8 : 1)))
                    }
                    if state != .transcribing, Int(t * 2) % 2 == 0 {
                        let caret = CGRect(x: size.width * 0.46 + 4, y: top + 18 - 4.5, width: 3, height: 13)
                        canvas.fill(Path(roundedRect: caret, cornerRadius: 1.5), with: .color(Brand.coralTop))
                    }
                default:
                    break
                }
            }
        }
    }
}
