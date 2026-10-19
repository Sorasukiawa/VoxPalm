import AppKit
import SwiftUI
import VoxPalmEngine
import VoxPalmVoice

/// 点菜单栏图标弹出的面板：先告诉你怎么说话，再是控制 / 收音 / 出字三行、最近出字、监听开关。
struct MenuContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let attention = model.attentions.first {
                AttentionBanner(attention: attention) { model.openSettings(attention.fix) }
            }
            TalkCard()
            VStack(spacing: 0) {
                row("控制") {
                    Text(model.activeDeviceName ?? "还没选").lineLimit(1)
                } trailing: {
                    if model.isPaused {
                        StatusDot(color: .secondary, text: "已暂停")
                    } else if model.config.controlDeviceIDs.isEmpty {
                        EmptyView()
                    } else if model.activeDeviceConnected {
                        StatusDot(color: .green, text: "已连接")
                    } else {
                        StatusDot(color: .orange, text: "没连上")
                    }
                }
                Divider()
                row("收音") {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.selectedMic?.name ?? "系统默认输入").lineLimit(1)
                        if let mic = model.selectedMic, mic.isLowRateBluetoothInput {
                            Text("蓝牙通话音质，转写会差一些").font(.caption).foregroundStyle(.orange)
                        }
                    }
                } trailing: {
                    HStack(spacing: 6) {
                        LevelBars(level: model.micLevel, live: model.voiceState == .listening || model.voiceState == .armed)
                        if let mic = model.selectedMic {
                            Chip(text: "\(Int(mic.nominalSampleRate / 1000)) kHz", warn: mic.isLowRateBluetoothInput)
                        }
                    }
                }
                Divider()
                row("出字") { Text(model.outputSummary).lineLimit(1) } trailing: { EmptyView() }
            }
            if let transcript = model.lastTranscript {
                RecentTranscript(text: transcript, at: model.lastTranscriptAt)
            } else if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            footer
        }
        .padding(14)
        .frame(width: 340)
        .tint(Brand.coralBottom)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let icon = NSImage(named: "VoxPalm") {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            }
            Text("掌声").font(.headline)
            Spacer()
            StatePill()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("设置…") { model.openSettings() }
            Toggle("监听", isOn: Binding(get: { !model.isPaused }, set: { model.setPaused(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("关掉后掌声不读按键，遥控器照常控制别的 App")
            Spacer()
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private func row<Leading: View, Trailing: View>(_ title: String, @ViewBuilder _ leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).foregroundStyle(.secondary).frame(width: 34, alignment: .leading)
            leading()
            Spacer(minLength: 6)
            trailing()
        }
        .font(.callout)
        .padding(.vertical, 8)
    }
}

/// 面板右上角的状态标签。
struct StatePill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            if let since = model.talkStartedAt, model.voiceState == .listening {
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text("正在听 " + SpeechHUDView.clock(context.date.timeIntervalSince(since))).monospacedDigit()
                }
            } else {
                Text(text)
            }
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .background(Capsule().fill(color.opacity(0.14)))
    }

    private var text: String {
        switch model.voiceState {
        case .armed: return "准备中"
        case .listening: return "正在听"
        case .transcribing: return "转写中"
        case .idle:
            if model.isPaused { return "已暂停" }
            return model.attentions.isEmpty ? "待命" : "要处理"
        }
    }

    private var color: Color {
        switch model.voiceState {
        case .armed, .listening: return Brand.coralBottom
        case .transcribing: return Color(red: 0.38, green: 0.35, blue: 0.65)
        case .idle:
            if model.isPaused { return .secondary }
            return model.attentions.isEmpty ? .secondary : .orange
        }
    }
}

/// 最上面一块：当前的说话键（「长按 确认键 说话」）和「按住试一下」；说话时换成实时声波和计时。
struct TalkCard: View {
    @Environment(AppModel.self) private var model
    @State private var trying = false

    var body: some View {
        Group {
            switch model.voiceState {
            case .armed, .listening:
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 10) {
                        Circle().fill(Brand.coral).frame(width: 14, height: 14)
                        LevelWave(level: model.micLevel)
                            .frame(width: 92, height: 18)
                        if let since = model.talkStartedAt {
                            TimelineView(.periodic(from: since, by: 1)) { context in
                                Text(SpeechHUDView.clock(context.date.timeIntervalSince(since)))
                                    .font(.title3.monospacedDigit().weight(.medium))
                                    .foregroundStyle(Brand.coralText)
                            }
                        }
                    }
                    Text(trying ? "松开按钮出字" : (model.talkKey?.releaseHint ?? "说完出字")).font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Brand.coralTop.opacity(0.16)))
            case .transcribing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在转文字……")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            case .idle:
                idle
            }
        }
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key = model.talkKey {
                HStack(spacing: 6) {
                    GestureGlyph(gesture: key.gesture)
                    Text(key.gesture.title).font(.title3.weight(.semibold))
                    KeyChip(name: key.keyName)
                    Text(key.verb).font(.title3.weight(.semibold))
                }
                Text("\(model.activeDeviceName ?? "控制设备") · 松手后字贴到光标处").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("还没设说话键").font(.headline)
                Text("在「按键」里把一个键的长按设成「按住说话」。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                PressToTalkButton(trying: $trying)
                if model.talkKey == nil {
                    Button("设一个说话键") { model.openSettings(.keys) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// 「按住试一下」：按下开麦，松手出字。
struct PressToTalkButton: View {
    @Environment(AppModel.self) private var model
    @Binding var trying: Bool

    var body: some View {
        Text("按住试一下")
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(trying ? Brand.coralTop.opacity(0.25) : Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !trying else { return }
                        trying = true
                        model.tryPress(true)
                    }
                    .onEnded { _ in
                        trying = false
                        model.tryPress(false)
                    }
            )
            .help("按住这个按钮说话，松开出字")
    }
}

/// 手势的小图形：单击一个点、双击两个点、长按一条横杠（设计稿键位表的列头）。
struct GestureGlyph: View {
    let gesture: GestureKind

    var body: some View {
        switch gesture {
        case .single: Circle().fill(Brand.coral).frame(width: 7, height: 7)
        case .double: HStack(spacing: 2) { Circle().frame(width: 6, height: 6); Circle().frame(width: 6, height: 6) }.foregroundStyle(Brand.coral)
        case .long: Capsule().fill(Brand.coral).frame(width: 18, height: 6)
        }
    }
}

/// 键名的小方块，例如 [确认键]。
struct KeyChip: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.2)))
    }
}

struct Chip: View {
    let text: String
    var warn = false

    var body: some View {
        Text(text)
            .font(.caption.monospacedDigit().weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(warn ? Color.orange : Color.secondary)
            .background(Capsule().fill((warn ? Color.orange : Color.primary).opacity(0.1)))
    }
}

struct StatusDot: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// 麦克风旁边的四根小电平条。
struct LevelBars: View {
    let level: Float
    let live: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let threshold = Float(index) / 4
                RoundedRectangle(cornerRadius: 1)
                    .fill(live && level > threshold ? Color.green : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(height: 14, alignment: .bottom)
    }
}

/// 面板里说话时的一排细竖条。
struct LevelWave: View {
    let level: Float

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = 11
                let gap = (size.width - 3 * Double(count)) / Double(count - 1)
                for index in 0..<count {
                    let wobble = 0.6 + 0.4 * sin(t * 10 + Double(index) * 1.3)
                    let h = max(3, size.height * min(1, (0.2 + Double(level) * 1.2) * wobble))
                    let rect = CGRect(x: Double(index) * (3 + gap), y: (size.height - h) / 2, width: 3, height: h)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Brand.coralTop))
                }
            }
        }
    }
}

/// 面板顶上的「要处理」提示条，带去哪里解决。
struct AttentionBanner: View {
    let attention: AppModel.Attention
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.title).font(.callout.weight(.semibold))
                Text(attention.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button("去打开", action: fix).controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.14)))
    }
}

/// 最近一次出字，可以拷贝。
struct RecentTranscript: View {
    static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    let text: String
    let at: Date?
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("最近出字").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let at { Text(Self.time.string(from: at)).font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                }
                Text(text).font(.callout).lineLimit(3).textSelection(.enabled)
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("拷贝")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}
