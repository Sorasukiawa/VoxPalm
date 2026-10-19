import SwiftUI
import VoxPalmEngine
import VoxPalmVoice

// 设置窗口里几块会动的小图：语音页的「出字方式」两张卡、Pro 页每个功能的小循环动画。

/// 出字方式：内置转写（● → 芯片 → 字）和外部输入法（● → 输入法 → 字），选中的那张虚线开始流动。
struct VoiceModeCards: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            card(.builtIn, title: "内置转写", detail: "掌声自己录音，在这台 Mac 上转成字，贴到光标处。声音不上传。", middle: "cpu")
            card(.inputMethod, title: "外部输入法", detail: "掌声替你按住输入法（豆包、微信输入法、系统听写）的语音键，让输入法出字。", middle: "globe")
        }
    }

    private func card(_ mode: VoiceSession.Mode, title: String, detail: String, middle: String) -> some View {
        let selected = model.config.voice.mode == mode
        return Button {
            withAnimation(Motion.pick(Motion.bounce)) { model.update { $0.voice.mode = mode } }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    node { Circle().fill(Brand.coral).frame(width: 12, height: 12) }
                    MarchingLine(running: selected)
                    node { Image(systemName: middle).font(.system(size: 14, weight: .medium)) }
                    MarchingLine(running: selected)
                    node { Image(systemName: "text.alignleft").font(.system(size: 13, weight: .medium)) }
                }
                .frame(height: 32)
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(selected ? Brand.coralTop.opacity(0.14) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(selected ? Brand.coralTop.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
    }

    private func node<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(width: 30, height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
    }
}

/// 一条往前走的虚线
private struct MarchingLine: View {
    let running: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !running || Motion.reduceMotion)) { context in
            let phase = running ? -context.date.timeIntervalSinceReferenceDate * 10 : 0
            Canvas { canvas, size in
                var line = Path()
                line.move(to: CGPoint(x: 0, y: size.height / 2))
                line.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                canvas.stroke(line, with: .color(running ? Brand.coralTop : Color.secondary.opacity(0.5)),
                              style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [4, 4], dashPhase: phase))
            }
        }
        .frame(height: 4)
    }
}

/// Pro 页的一个功能：上面一块几秒钟的小循环动画说明它干什么，下面标题和一句话。
struct ProFeatureCard: View {
    enum Kind: CaseIterable { case devices, perApp, daw, combo, words, phone }

    let kind: Kind

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: Motion.reduceMotion)) { context in
                viz(t: context.date.timeIntervalSinceReferenceDate)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: 58)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(0.05)))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title).font(.callout.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(cornerRadius: 16)
    }

    private var title: String {
        switch kind {
        case .devices: return "多台控制设备同时在线"
        case .perApp: return "多套键位方案，按 App 自动切换"
        case .daw: return "录音剪辑软件动作包"
        case .combo: return "组合动作"
        case .words: return "转写增强"
        case .phone: return "手机上的自定义面板"
        }
    }

    private var detail: String {
        switch kind {
        case .devices: return "遥控器、脚踏板、无线麦一起用"
        case .perApp: return "在剪辑软件里和在编程工具里，同一个键做不同的事"
        case .daw: return "Logic Pro、Final Cut Pro、Premiere Pro、DaVinci Resolve 等"
        case .combo: return "一个键依次执行多步"
        case .words: return "热词和自定义词表、口语润色"
        case .phone: return "掌声手机版按 Mac 当前的 App 换按键面板"
        }
    }

    @ViewBuilder
    private func viz(t: Double) -> some View {
        switch kind {
        case .devices:
            // 三台设备轮流亮
            let active = Int(t / 1.2) % 3
            HStack(spacing: 14) {
                ForEach(Array([DeviceDiagram.xiaomiRemote2, .footPedal, .presenter].enumerated()), id: \.offset) { index, diagram in
                    DeviceFigure(diagram: diagram, showsSymbols: false)
                        .frame(width: index == 1 ? 60 : 16, height: 42)
                        .shadow(color: index == active ? Brand.coralTop.opacity(0.9) : .clear, radius: 6)
                        .offset(y: index == active ? -2 : 0)
                        .animation(Motion.pick(Motion.bounce), value: active)
                }
            }
        case .perApp:
            let first = Int(t / 2) % 2 == 0
            VStack(spacing: 4) {
                Text(first ? "剪辑软件" : "Claude").font(.caption.weight(.semibold))
                Text(first ? "确认键 → 打标记" : "确认键 → 发送")
                    .font(.caption2.weight(.medium)).foregroundStyle(Brand.coralText)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Brand.coralTop.opacity(0.14)))
            }
            .id(first)
            .transition(.push(from: .bottom))
            .animation(Motion.pick(Motion.smooth), value: first)
        case .daw:
            Canvas { canvas, size in
                let tracks: [(CGFloat, CGFloat, CGFloat)] = [(0.04, 0.6, 12), (0.3, 0.96, 24), (0.04, 0.8, 36)]
                for track in tracks {
                    canvas.fill(Path(roundedRect: CGRect(x: size.width * track.0, y: track.2 - 4, width: size.width * (track.1 - track.0), height: 8), cornerRadius: 3),
                                with: .color(.secondary.opacity(0.35)))
                }
                let p = t.truncatingRemainder(dividingBy: 3) / 3
                let x = size.width * (0.04 + 0.92 * p)
                for mark in [0.35, 0.7] where p * 0.92 + 0.04 > mark {
                    canvas.fill(Path(CGRect(x: size.width * mark, y: 6, width: 2, height: size.height - 12)), with: .color(Brand.coralTop))
                }
                canvas.fill(Path(CGRect(x: x, y: 4, width: 2, height: size.height - 8)), with: .color(.primary))
            }
        case .combo:
            let active = Int(t / 0.6) % 5
            HStack(spacing: 5) {
                ForEach(Array(["切对话", "说话", "发送"].enumerated()), id: \.offset) { index, step in
                    if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                    Text(step).font(.caption2.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .foregroundStyle(index == active ? .white : .primary)
                        .background(RoundedRectangle(cornerRadius: 7).fill(index == active ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(Color.primary.opacity(0.07))))
                        .animation(Motion.pick(Motion.bounce), value: active)
                }
            }
        case .words:
            let p = min(1, max(0, (t.truncatingRemainder(dividingBy: 3) - 0.4) / 0.6))
            HStack(spacing: 3) {
                Text("把")
                underlined("VoxPalm", p)
                Text("的")
                underlined("PR", min(1, max(0, p * 1.4 - 0.3)))
                Text("合进去")
            }
            .font(.caption)
        case .phone:
            let lit = Int(t / 2) % 2 == 1
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 7).stroke(Color.secondary, lineWidth: 1.5).frame(width: 30, height: 46)
                LazyVGrid(columns: [GridItem(.fixed(9)), GridItem(.fixed(9))], spacing: 3) {
                    ForEach(0..<4, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 2.5).fill(lit ? Color.tilePurple : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                    }
                }
                .padding(.bottom, 16)
                Circle().fill(Brand.coralTop).frame(width: 7, height: 7).padding(.bottom, 5)
            }
            .animation(Motion.pick(Motion.smooth), value: lit)
        }
    }

    private func underlined(_ text: String, _ progress: Double) -> some View {
        Text(text).fontWeight(.semibold)
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Capsule().fill(Brand.coralTop).frame(width: geometry.size.width * progress, height: 2)
                        .offset(y: geometry.size.height)
                }
            }
    }
}
