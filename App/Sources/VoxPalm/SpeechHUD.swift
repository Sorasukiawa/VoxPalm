import AppKit
import Observation
import SwiftUI
import VoxPalmVoice

/// 说话浮窗的状态（design/VoxPalm-Motion.html「说话浮窗」一节）。
/// 顺序照 Logo 的三段走：● 按下 → 声波在听 → 字行出字。
enum HUDState: Equatable {
    case hidden
    /// 按下了，还没满长按时间：只有 ●，外圈按长按时间走满
    case armed(since: Date, threshold: Double)
    case listening(since: Date, subtitle: String)
    /// 外部输入法模式：替用户按住了输入法的语音键
    case inputMethod(since: Date, subtitle: String)
    case transcribing
    case done(characters: Int, app: String?, snippet: String?)
    case handedOff
    /// 一句提示：按得太短、没听到声音、贴不进去、出错。会就地摇一下。
    case message(title: String, subtitle: String?, tone: Tone)

    enum Tone: Equatable { case muted, warn, error }

    var dotColor: Color {
        switch self {
        case .hidden, .armed, .listening, .inputMethod: return Brand.coralTop
        case .transcribing: return HUDColors.lavender
        case .done, .handedOff: return HUDColors.ok
        case let .message(_, _, tone):
            switch tone {
            case .muted: return HUDColors.fg2
            case .warn: return HUDColors.warn
            case .error: return HUDColors.err
            }
        }
    }

    var since: Date? {
        switch self {
        case let .listening(since, _), let .inputMethod(since, _): return since
        default: return nil
        }
    }

    var isCoral: Bool {
        switch self {
        case .armed, .listening, .inputMethod: return true
        default: return false
        }
    }
}

enum HUDColors {
    static let background = Color(red: 28 / 255, green: 25 / 255, blue: 38 / 255).opacity(0.9)
    static let line = Color(red: 1, green: 243 / 255, blue: 234 / 255).opacity(0.1)
    static let fg = Color(red: 1, green: 243 / 255, blue: 234 / 255)
    static let fg2 = Color(red: 1, green: 243 / 255, blue: 234 / 255).opacity(0.62)
    static let ok = Color(red: 0x5D / 255, green: 0xD3 / 255, blue: 0x9A / 255)
    static let warn = Color(red: 0xF5 / 255, green: 0xB7 / 255, blue: 0x4E / 255)
    static let err = Color(red: 1, green: 0x7A / 255, blue: 0x6E / 255)
    static let lavender = Color(red: 0xB3 / 255, green: 0xAD / 255, blue: 0xE6 / 255)
    static let coralDeep = Color(red: 0xA9 / 255, green: 0x3F / 255, blue: 0x1C / 255)
}

@MainActor
@Observable
final class HUDModel {
    var state: HUDState = .hidden
    var level: Float = 0
    /// 收起前先缩回只剩 ●
    var collapsed = false
    /// 每加一就摇一下（按得太短、出错）
    var shakes: CGFloat = 0
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
        model.onVoiceOutcome = { [weak self] outcome in
            // 出字结果先到、转写的字后到：等一拍再显示，「已输入」下面才有开头几个字。
            DispatchQueue.main.async { self?.outcome(outcome) }
        }
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

    /// 副标题只写设备名；收音是蓝牙通话音质时才多一句提醒（2026-10-19 本人定）。
    private var subtitle: String {
        let device = model.activeShortName ?? "按键"
        if let mic = model.selectedMic, mic.isLowRateBluetoothInput { return "\(device) · \(mic.name) 通话音质" }
        return device
    }

    private func voiceStateChanged(_ state: VoiceSession.State) {
        switch state {
        case .armed:
            // 短按（单击）会马上放弃预录，晚 0.15 秒再出浮窗，免得一闪而过。
            let since = model.talkStartedAt ?? Date()
            let threshold = model.config.timing.longPressThreshold
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.model.voiceState == .armed else { return }
                self.show(.armed(since: since, threshold: threshold))
            }
            armedWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        case .listening:
            armedWork?.cancel()
            let since = model.talkStartedAt ?? Date()
            if model.config.voice.mode == .inputMethod {
                show(.inputMethod(since: since, subtitle: subtitle))
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
            let snippet = model.lastTranscript.map { text in "「\(text.count > 12 ? String(text.prefix(12)) + "…" : text)」" }
            show(.done(characters: count, app: app, snippet: snippet), hideAfter: 1.8)
        case .handedToInputMethod:
            show(.handedOff, hideAfter: 1.5)
        case let .copied(_, reason):
            show(.message(title: "字在剪贴板里，按 ⌘V", subtitle: reason.pasteMessage, tone: .warn), hideAfter: 4)
        case let .tooShort(threshold):
            show(.message(title: String(format: "按住超过 %.1f 秒才算", threshold), subtitle: nil, tone: .muted), hideAfter: 1.3)
        case .noAudio:
            show(.message(title: "没听到声音", subtitle: "看看麦克风开了没有，或者在面板里换一个", tone: .muted), hideAfter: 4)
        case .noText:
            show(.message(title: "没听出字", subtitle: "再说一次，离麦克风近一点", tone: .muted), hideAfter: 4)
        case let .failed(message):
            show(.message(title: "这次没转成字", subtitle: String(message.prefix(40)), tone: .error), hideAfter: 4)
        }
    }

    func show(_ state: HUDState, hideAfter delay: Double? = nil) {
        hideWork?.cancel()
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
        withAnimation(Motion.pick(Motion.bounce)) {
            hud.collapsed = false
            hud.state = state
        }
        if case .message = state, !Motion.reduceMotion {
            withAnimation(.easeOut(duration: 0.42)) { hud.shakes += 1 }
        }
        if let delay { hide(after: delay) }
    }

    /// 先缩回只剩 ●，再往下掉着淡出，最后把窗口收起来。
    private func hide(after delay: Double) {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(Motion.pick(Motion.bounce)) { self.hud.collapsed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + (Motion.reduceMotion ? 0 : 0.26)) { [weak self] in
                guard let self, self.hud.collapsed else { return }
                withAnimation(Motion.pick(Motion.exit)) { self.hud.state = .hidden }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                    guard let self, self.hud.state == .hidden else { return }
                    self.panel.orderOut(nil)
                }
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 透明画布的大小，比最长的一条提示宽；浮窗不接鼠标，空白处不挡操作。
    private static let canvas = NSSize(width: 640, height: 120)

    /// 放在鼠标所在屏幕的下方正中、程序坞上面。
    private func layout() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: visible.midX - Self.canvas.width / 2, y: visible.minY - 2,
                              width: Self.canvas.width, height: Self.canvas.height), display: false)
    }
}

/// 深色半透明胶囊：按下时只有 ●，满了才展开成 ● + 声波 / 字行 + 标题副标题 + 计时。深浅色模式下都一样。
struct SpeechHUDView: View {
    let hud: HUDModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if hud.state != .hidden {
                capsule
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.6, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 16)),
                        removal: .scale(scale: 0.7, anchor: .bottom).combined(with: .opacity).combined(with: .offset(y: 10))))
            }
        }
        // 阴影往下偏，底下多留一些，免得被窗口边切掉
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 40)
    }

    private var expanded: Bool {
        if hud.collapsed { return false }
        if case .armed = hud.state { return false }
        return true
    }

    private var capsule: some View {
        HStack(spacing: 0) {
            HUDDot(state: hud.state)
                .frame(width: 44, height: 44)
            if expanded {
                HStack(spacing: 10) {
                    if showsSignal {
                        HUDSignal(state: hud.state, level: hud.level)
                            .frame(width: 46, height: 24)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(HUDColors.fg).lineLimit(1)
                        if let subtitle {
                            Text(subtitle).font(.system(size: 11)).foregroundStyle(HUDColors.fg2).lineLimit(1)
                                .frame(maxWidth: 260, alignment: .leading)
                        }
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    if let since = hud.state.since {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(Self.clock(context.date.timeIntervalSince(since)))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(HUDColors.fg2)
                                .contentTransition(.numericText())
                        }
                    }
                }
                .padding(.trailing, 16)
                .transition(.opacity.animation(.easeOut(duration: 0.2).delay(Motion.reduceMotion ? 0 : 0.08)))
            }
        }
        .frame(height: 44)
        .background(Capsule().fill(HUDColors.background).shadow(color: .black.opacity(0.38), radius: 14, y: 7))
        .overlay(Capsule().strokeBorder(HUDColors.line, lineWidth: 0.5))
        .clipShape(Capsule())
        .modifier(Shake(amount: hud.shakes))
        .fixedSize()
    }

    private var showsSignal: Bool {
        switch hud.state {
        case .message, .hidden: return false
        default: return true
        }
    }

    private var title: String {
        switch hud.state {
        case .hidden, .armed: return ""
        case .listening: return "正在听"
        case .inputMethod: return "输入法在听"
        case .transcribing: return "转写中"
        case let .done(count, app, _): return app.map { "已输入 \(count) 字 · \($0)" } ?? "已输入 \(count) 字"
        case .handedOff: return "交给输入法了"
        case let .message(title, _, _): return title
        }
    }

    private var subtitle: String? {
        switch hud.state {
        case .hidden, .armed: return nil
        case let .listening(_, subtitle), let .inputMethod(_, subtitle): return subtitle
        case .transcribing: return "在这台 Mac 上"
        case let .done(_, _, snippet): return snippet
        case .handedOff: return "字由输入法放进去"
        case let .message(_, subtitle, _): return subtitle
        }
    }

    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 左右摇一下（按得太短、出错）。
struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        let phase = amount - amount.rounded(.down)
        let x = phase == 0 ? 0 : 5 * sin(phase * .pi * 4) * (1 - phase)
        return ProjectionTransform(CGAffineTransform(translationX: x, y: 0))
    }
}

/// 左边的 ●：录音时珊瑚色带厚度；准备中一跳一跳、外圈一圈按长按时间走满；正在听时外圈一圈圈扩散。
struct HUDDot: View {
    let state: HUDState

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if case let .armed(since, threshold) = state {
                    let progress = min(1, max(0, context.date.timeIntervalSince(since) / max(threshold, 0.05)))
                    Circle().stroke(HUDColors.fg.opacity(0.14), lineWidth: 2.5).frame(width: 30, height: 30)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Brand.coralTop, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: 30, height: 30)
                }
                if case .listening = state { ring(t) }
                if case .inputMethod = state { ring(t) }
                Circle()
                    .fill(state.isCoral ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(state.dotColor))
                    .shadow(color: state.isCoral ? HUDColors.coralDeep : .clear, radius: 0, y: 2)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse(t))
            }
        }
    }

    private func pulse(_ t: Double) -> CGFloat {
        guard case .armed = state, !Motion.reduceMotion else { return 1 }
        return 0.74 + 0.26 * (0.5 + 0.5 * cos(2 * .pi * t / 0.8))
    }

    private func ring(_ t: Double) -> some View {
        let p = (t.truncatingRemainder(dividingBy: 1.3)) / 1.3
        return Circle()
            .stroke(Brand.coralTop.opacity(Motion.reduceMotion ? 0 : 0.8 * (1 - p)), lineWidth: 2)
            .frame(width: 14 + 16 * p, height: 14 + 16 * p)
    }
}

/// 中间的信号区：录音时 7 根竖条跟着音量跳；松手后竖条压扁成三行字，一行行闪着填满；出字后停住并亮一个光标。
struct HUDSignal: View {
    let state: HUDState
    let level: Float

    private static let shape: [Double] = [0.45, 0.75, 1, 0.85, 0.6, 0.9, 0.5]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                switch state {
                case .armed, .listening, .inputMethod:
                    let count = Self.shape.count
                    let width = 3.5
                    let gap = (size.width - width * Double(count)) / Double(count - 1)
                    for index in 0..<count {
                        // 音量决定整体高度，每根加一点各自的起伏
                        let wobble = 0.75 + 0.25 * sin(t * 9 + Double(index) * 1.7)
                        let scale = max(0.15, min(1, Self.shape[index] * (0.25 + 1.1 * Double(level)) * wobble))
                        let h = 22 * scale
                        let rect = CGRect(x: Double(index) * (width + gap), y: (size.height - h) / 2, width: width, height: h)
                        canvas.fill(Path(roundedRect: rect, cornerRadius: width / 2),
                                    with: .linearGradient(Gradient(colors: [Brand.coralTop, Brand.coralBottom]),
                                                          startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                    }
                case .transcribing, .done, .handedOff:
                    let widths = [1.0, 0.76, 0.44]
                    let lineHeight = 3.5
                    let top = (size.height - (3 * lineHeight + 2 * 4.5)) / 2
                    for (index, width) in widths.enumerated() {
                        var fill = 1.0
                        if case .transcribing = state, !Motion.reduceMotion {
                            let p = (t - Double(index) * 0.14).truncatingRemainder(dividingBy: 1)
                            fill = 0.15 + 0.85 * min(1, (p < 0 ? p + 1 : p) / 0.6)
                        }
                        let rect = CGRect(x: 0, y: top + Double(index) * (lineHeight + 4.5), width: size.width * width * fill, height: lineHeight)
                        canvas.fill(Path(roundedRect: rect, cornerRadius: lineHeight / 2), with: .color(HUDColors.fg.opacity(state == .transcribing ? 0.8 : 1)))
                    }
                    if state != .transcribing, Int(t * 2) % 2 == 0 {
                        let caret = CGRect(x: size.width * 0.44 + 3, y: top + 2 * (lineHeight + 4.5) - 4, width: 2.5, height: 11)
                        canvas.fill(Path(roundedRect: caret, cornerRadius: 1.25), with: .color(Brand.coralTop))
                    }
                default:
                    break
                }
            }
        }
    }
}
