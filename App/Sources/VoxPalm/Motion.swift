import AppKit
import SwiftUI

// 全 App 统一的动效（design/VoxPalm-Motion.html「动效规范」一节）：按下、弹、顺、收、循环、依次。
// 系统打开「减少动态效果」时，一律换成很短的淡入淡出。

enum Motion {
    /// 按下反馈：按钮、键帽按下，示意图上的键闪一下
    static let press = Animation.easeOut(duration: 0.09)
    /// 弹：浮窗冒出和展开、选中底色滑动、转盘停下、开关、勾号
    static let bounce = Animation.spring(duration: 0.42, bounce: 0.2)
    /// 顺：换步、换页、面板长高、窗口收进菜单栏、引线画出来
    static let smooth = Animation.smooth(duration: 0.5)
    /// 收：浮窗消失、面板关掉、旧页淡出
    static let exit = Animation.easeIn(duration: 0.2)
    /// 减少动态效果时用的淡入淡出
    static let reduced = Animation.easeInOut(duration: 0.12)

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// 按系统设置挑动画：减少动态效果时换成淡入淡出。
    static func pick(_ animation: Animation) -> Animation { reduceMotion ? reduced : animation }

    /// 依次浮上来：第 index 个晚 0.04 秒
    static func stagger(_ index: Int, base: Double = 0.08) -> Animation {
        reduceMotion ? reduced : bounce.delay(base + 0.045 * Double(index))
    }
}

/// 进来时从旁边滑进、依次浮上来。换步时整页重建，onAppear 会再触发一次。
struct StaggerIn: ViewModifier {
    let index: Int
    var dx: CGFloat = 0
    var dy: CGFloat = 10
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(x: shown || Motion.reduceMotion ? 0 : dx, y: shown || Motion.reduceMotion ? 0 : dy)
            .onAppear { withAnimation(Motion.stagger(index)) { shown = true } }
    }
}

extension View {
    func staggerIn(_ index: Int, dx: CGFloat = 0, dy: CGFloat = 10) -> some View {
        modifier(StaggerIn(index: index, dx: dx, dy: dy))
    }
}

/// 掌声的 Logo，能按：按住时 ● 按下去、声波跟着跳、字行收起；松手后字行一行行写出来，光标落到最后。
/// 第一次出现时按 ● → 声波 → 字的顺序长出来，讲的就是掌声干的事。Canvas 里的东西不吃 withAnimation，所以按时间算每一帧。
struct LogoMark: View {
    var size: CGFloat
    var interactive = true
    /// 外面按住（比如空格）时也会动
    var held = false
    @State private var introAt: Date?
    @State private var pressAt: Date?
    @State private var releaseAt: Date?
    @State private var animating = false
    @State private var stopWork: DispatchWorkItem?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !animating)) { context in
            Canvas { canvas, canvasSize in
                draw(in: &canvas, size: canvasSize, now: context.date)
            }
        }
        .frame(width: size, height: size)
        .shadow(color: Brand.coralBottom.opacity(0.32), radius: size * 0.12, y: size * 0.06)
        .contentShape(RoundedRectangle(cornerRadius: size * 0.2))
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in if interactive { press() } }
            .onEnded { _ in if interactive { release() } })
        .onAppear(perform: intro)
        .onChange(of: held) { _, down in if down { press() } else { release() } }
        .accessibilityLabel("掌声 Logo，按住试试")
    }

    func press() {
        guard pressAt == nil else { return }
        pressAt = Date()
        releaseAt = nil
        keepAnimating(nil)
    }

    func release() {
        guard pressAt != nil else { return }
        releaseAt = Date()
        pressAt = nil
        keepAnimating(1.4)
    }

    private func intro() {
        guard introAt == nil, !Motion.reduceMotion else { return }
        introAt = Date()
        keepAnimating(1.3)
    }

    /// 动画期间让 TimelineView 一直跑，停下后不占 CPU。
    private func keepAnimating(_ seconds: Double?) {
        stopWork?.cancel()
        animating = true
        guard let seconds else { return }
        let work = DispatchWorkItem { if pressAt == nil { animating = false } }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }
    private static func easeOut(_ x: Double) -> Double { 1 - pow(1 - clamp(x), 3) }
    private static func easeOutBack(_ x: Double) -> Double {
        let c = 1.4, t = clamp(x) - 1
        return 1 + (c + 1) * t * t * t + c * t * t
    }
    private static func jitter(_ t: Double, _ index: Int) -> Double {
        0.3 + 0.7 * abs(sin(t * (5.5 + Double(index) * 2.6) + Double(index))) * (0.7 + 0.3 * sin(t * 13 + Double(index)))
    }

    // 坐标照 brand/icon/VoxPalm-icon.svg（1024 画布）
    private func draw(in canvas: inout GraphicsContext, size: CGSize, now: Date) {
        let k = size.width / 1024
        let t = now.timeIntervalSinceReferenceDate
        func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect { CGRect(x: x * k, y: y * k, width: w * k, height: h * k) }
        func capsule(_ r: CGRect) -> Path { Path(roundedRect: r, cornerRadius: min(r.width, r.height) / 2) }
        let coral = Gradient(colors: [Brand.coralTop, Brand.coralBottom])
        func coralFill(_ r: CGRect) -> GraphicsContext.Shading {
            .linearGradient(coral, startPoint: CGPoint(x: r.midX, y: r.minY), endPoint: CGPoint(x: r.midX, y: r.maxY))
        }
        let sinceIntro = introAt.map { now.timeIntervalSince($0) } ?? 10
        let sincePress = pressAt.map { now.timeIntervalSince($0) }
        let sinceRelease = releaseAt.map { now.timeIntervalSince($0) }

        let bg = rect(100, 100, 824, 824)
        canvas.fill(Path(roundedRect: bg, cornerRadius: 196 * k, style: .continuous),
                    with: .linearGradient(Gradient(colors: [Brand.inkTop, Brand.inkBottom]), startPoint: CGPoint(x: bg.midX, y: bg.minY), endPoint: CGPoint(x: bg.midX, y: bg.maxY)))
        canvas.stroke(Path(roundedRect: rect(103, 103, 818, 818), cornerRadius: 193 * k, style: .continuous),
                      with: .color(Color(red: 0.42, green: 0.40, blue: 0.56).opacity(0.45)), lineWidth: 6 * k)
        // ● 按钮：先弹出来；按下时顶面落到厚度的位置
        let r = 70 * max(0.05, Self.easeOutBack((sinceIntro - 0.1) / 0.42))
        canvas.fill(Path(ellipseIn: rect(262 - r, 523.2 - r, r * 2, r * 2)), with: .color(Color(red: 0.663, green: 0.247, blue: 0.11)))
        let top = rect(262 - r, (sincePress != nil ? 523.2 : 512) - r, r * 2, r * 2)
        canvas.fill(Path(ellipseIn: top), with: coralFill(top))
        // 两根声波：长出来；按住时跟着跳，松手后回到原样
        for (index, bar) in [(356.0, 312.0, 400.0), (440.0, 382.0, 260.0)].enumerated() {
            var scale = Self.easeOutBack((sinceIntro - 0.25 - 0.09 * Double(index)) / 0.45)
            if sincePress != nil {
                scale = Self.jitter(t, index)
            } else if let sinceRelease, let releasedAt = releaseAt?.timeIntervalSinceReferenceDate {
                let from = Self.jitter(releasedAt, index)
                scale = from + (1 - from) * Self.easeOutBack(sinceRelease / 0.45)
            }
            let h = bar.2 * max(0, scale)
            guard h > 1 else { continue }
            let r = rect(bar.0, bar.1 + (bar.2 - h) / 2, 56, h)
            canvas.fill(capsule(r), with: coralFill(r))
        }
        // 三行字：一行接一行从左往右写出来；按住时缩成一点
        var allShown = true
        for (index, line) in [(392.0, 288.0), (484.0, 238.0), (576.0, 136.0)].enumerated() {
            var p = Self.easeOut((sinceIntro - 0.45 - 0.12 * Double(index)) / 0.4)
            if let sincePress {
                p = 1 - Self.easeOut(sincePress / 0.18) * 0.95
            } else if let sinceRelease {
                p = max(0.05, Self.easeOut((sinceRelease - 0.2 - 0.15 * Double(index)) / 0.42))
            }
            if p < 0.999 { allShown = false }
            guard p > 0.01 else { continue }
            let w = max(56 * 0.25, line.1 * p)
            canvas.fill(capsule(rect(532, line.0, w, 56)), with: .color(Brand.cream.opacity(sincePress != nil ? 0.3 : 1)))
        }
        if allShown {
            canvas.fill(capsule(rect(692, 566, 24, 76)), with: .color(Brand.coralTop))
        }
    }
}

/// 示意图上「亮着」的键：一圈珊瑚色往外扩，键面一呼一吸。
struct LitRing: View {
    let frame: CGRect
    let isCircle: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.5) / 1.5
            let breath = 0.38 + 0.24 * (0.5 + 0.5 * sin(context.date.timeIntervalSinceReferenceDate * 2 * .pi / 1.5))
            ZStack {
                shape.fill(Brand.coralTop.opacity(breath))
                shape.stroke(Brand.coralTop.opacity(0.95 * (1 - p)), lineWidth: 2)
                    .scaleEffect(Motion.reduceMotion ? 1 : 1 + 0.9 * p)
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
        }
        .allowsHitTesting(false)
    }

    private var shape: AnyShape {
        isCircle ? AnyShape(Circle()) : AnyShape(Capsule())
    }
}
