import AppKit
import SwiftUI
import VoxPalmEngine
import VoxPalmVoice

/// 点菜单栏图标弹出的面板（design/VoxPalm-Motion.html「日常使用」）：
/// 上面一块「怎么说话」，按住时就地变成声波 + 计时；控制、收音两块磁贴点开就地换设备；最近出的字可以拷贝。
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Tile?
    @State private var outputHover = false

    enum Tile { case control, mic }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header.staggerIn(0, dy: 6)
            if let attention = model.attentions.first {
                AttentionBanner(attention: attention) {
                    if let permission = attention.permission {
                        model.closePanel()
                        permission.request()
                    } else if attention.retry {
                        model.retryControlDevice()
                    } else {
                        model.openSettings(attention.fix)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .staggerIn(1, dy: 6)
            }
            TalkCard().staggerIn(2, dy: 6)
            Group {
                switch expanded {
                case .control: ControlSwitcher(close: collapse)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                case .mic: MicSwitcher(close: collapse)
                    .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
                case nil:
                    tiles.transition(.opacity)
                    if let note = model.micAvoidNote {
                        MicAvoidNote(text: note).transition(.opacity)
                    }
                    outputRow.transition(.opacity)
                }
            }
            .staggerIn(3, dy: 6)
            RecentList().staggerIn(4, dy: 6)
            footer.staggerIn(5, dy: 6)
        }
        .padding(14)
        .frame(width: 340)
        // 和引导、设置窗口一样，左上角透一点珊瑚色的光
        .background(BrandBackdrop(opaque: false))
        .tint(Brand.coralBottom)
        .animation(Motion.pick(Motion.smooth), value: expanded)
        .animation(Motion.pick(Motion.smooth), value: model.attentions.map(\.id))
        .animation(Motion.pick(Motion.bounce), value: model.recentTranscripts.map(\.id))
    }

    private func collapse() { expanded = nil }

    private var header: some View {
        HStack(spacing: 8) {
            AppIconImage(size: 22)
            Text("掌声").font(.system(size: 15, weight: .bold))
            Spacer()
            StatePill()
        }
    }

    private var tiles: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { expanded = .control } label: {
                DeviceTile(label: "控制", name: model.activeShortName ?? "还没选", art: model.activePickerDevice?.art ?? PickerArt.box) {
                    if model.isPaused {
                        StatusPill(text: "已暂停", color: .secondary)
                    } else if model.config.controlDeviceIDs.isEmpty {
                        StatusPill(text: "去选一个", color: .orange)
                    } else if model.activeDeviceConnected {
                        StatusPill(text: "已连接", color: .tileGreen)
                    } else {
                        StatusPill(text: "没连上", color: .orange)
                    }
                }
            }
            .buttonStyle(TileButtonStyle())
            .help("点开换控制设备")
            Button { expanded = .mic } label: {
                // 选的麦会被控制设备静音时，磁贴直接画这次换上的那支（下面一行说明为什么）
                let route = model.micRoute
                // 选的麦没连上：和控制磁贴一样写「没连上」，不画成系统默认那支（录音这时落到系统默认输入上）
                let missing = route.avoided == nil && model.selectedMicMissing
                let mic = route.avoided != nil
                    ? model.pickerMics.first { $0.uid != nil && $0.uid == route.device?.uid }
                    : model.pickerMics.first { $0.uid == model.config.voice.micUID } ?? model.pickerMics.first
                DeviceTile(label: "收音", name: missing ? "已选的麦" : mic?.shortName ?? "系统默认输入",
                           art: missing ? PickerArt.system : mic?.art ?? PickerArt.system) {
                    HStack(spacing: 6) {
                        // 说话时显示跳动的声波；平时写是哪种麦（不放像信号格的图标）
                        if model.voiceState == .listening || model.voiceState == .armed {
                            LevelWave(level: model.micLevel).frame(width: 44, height: 12)
                        } else if missing {
                            StatusPill(text: "没连上", color: .orange)
                        } else if let recording = model.recordingMic {
                            Text(DevicesPane.transportName(recording)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if let recording = model.recordingMic {
                            Chip(text: "\(Int(recording.nominalSampleRate / 1000)) kHz", warn: recording.isLowRateBluetoothInput)
                        }
                    }
                }
            }
            .buttonStyle(TileButtonStyle())
            .help(model.selectedMicMissing ? "选的麦没连上，先用系统默认输入收音。点开换收音设备" : "点开换收音设备")
        }
        // 两块一样高：哪块多一行、少一行（没连上、没有采样率）都按高的那块拉齐
        .fixedSize(horizontal: false, vertical: true)
    }

    private var outputRow: some View {
        Button { model.openSettings(.voice) } label: {
            HStack(spacing: 9) {
                IconTile(symbol: "text.alignleft", color: .tileGreen, size: 22)
                Text("出字").font(.callout).foregroundStyle(.secondary)
                Text(model.outputSummary).font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.primary.opacity(outputHover ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .onHover { outputHover = $0 }
        .help("打开设置的语音页")
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("监听", isOn: Binding(get: { !model.isPaused }, set: { model.setPaused(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("关掉后掌声不读按键，遥控器照常控制别的 App（也可以按住 ⌥ 点菜单栏图标）")
            Spacer()
            Button { model.openSettings() } label: { Label("设置…", systemImage: "gearshape") }
                .secondaryButton()
                .controlSize(.small)
                .keyboardShortcut(",", modifiers: .command)
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, 2)
        }
        .font(.callout)
        .padding(.top, 2)
    }
}

/// 收音避开了被控制设备静音的麦时，磁贴下面的一句说明
private struct MicAvoidNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: "mic.slash.fill").font(.caption).foregroundStyle(Color.tileOrange)
            Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 磁贴按下时缩一点
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Motion.press, value: configuration.isPressed)
    }
}

/// 面板里的一块磁贴：设备缩略图、「控制 / 收音」、名字，下面一行状态。
struct DeviceTile<Status: View>: View {
    let label: String
    let name: String
    let art: DeviceDiagram
    @ViewBuilder let status: () -> Status
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                DeviceFigure(diagram: art, showsSymbols: false)
                    .frame(width: 28, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(name).font(.callout.weight(.semibold)).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
            }
            // 状态行固定高度（状态胶囊的高度）：胶囊、采样率小标签、声波、空着都占一样高，两块磁贴的状态行对齐
            status().frame(height: 22, alignment: .leading)
        }
        .padding(11)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(hovering ? 0.075 : 0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { hovering = $0 }
    }
}

/// 控制磁贴点开后：横排设备小图，点一下就换（像控制中心的模块就地放大）。
struct ControlSwitcher: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SwitcherHeader(title: "控制设备", link: "设备设置…", open: { model.openSettings(.devices) }, close: close)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.pickerDevices.filter(\.connected)) { item in
                        let selected = model.config.controlDeviceIDs.first == item.id
                        Button {
                            if let device = item.device { model.selectControlDevice(device.id) }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: close)
                        } label: {
                            VStack(spacing: 4) {
                                DeviceFigure(diagram: item.art, showsSymbols: false).frame(width: 66, height: 52)
                                Text(item.shortName).font(.caption).lineLimit(1)
                            }
                            .frame(width: 84)
                            .padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(selected ? Brand.coralTop.opacity(0.16) : Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(selected ? Brand.coralTop.opacity(0.5) : .clear, lineWidth: 1.5))
                        }
                        .buttonStyle(TileButtonStyle())
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// 收音磁贴点开后：麦克风列表，点一下就换。
struct MicSwitcher: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SwitcherHeader(title: "收音设备", link: "收音设置…", open: { model.openSettings(.devices, focus: .init(showsMics: true)) }, close: close)
            ForEach(model.pickerMics) { mic in
                let selected = model.config.voice.micUID == mic.uid
                Button {
                    model.update { $0.voice.micUID = mic.uid }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: close)
                } label: {
                    PickerRow(art: mic.art, title: mic.name, detail: mic.rowDetail, selected: selected)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        }
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.045)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

private struct SwitcherHeader: View {
    let title: String
    let link: String
    let open: () -> Void
    let close: () -> Void

    var body: some View {
        HStack {
            Text(title).font(.callout.weight(.semibold))
            Spacer()
            Button(link, action: open).buttonStyle(.link).font(.caption)
            Button(action: close) {
                Image(systemName: "chevron.up").font(.caption.weight(.bold)).frame(width: 22, height: 22)
            }
            .buttonStyle(.borderless)
            .help("收起")
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 2)
    }
}

/// 最近出的字：最多 3 条，鼠标移上去出现拷贝按钮；新的一条从上面滑进来。
struct RecentList: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.recentTranscripts.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                HStack {
                    Text("最近出字").fontWeight(.semibold).foregroundStyle(.secondary)
                    Spacer()
                    Text("只记在这次运行里").foregroundStyle(.tertiary)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
                ForEach(model.recentTranscripts) { record in
                    RecentRow(record: record)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        }
    }
}

private struct RecentRow: View {
    let record: AppModel.TranscriptRecord
    @State private var hovering = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(record.text).font(.callout.weight(.medium)).lineLimit(1).textSelection(.enabled)
                TimelineView(.periodic(from: record.at, by: 30)) { context in
                    Text("\(record.app ?? "剪贴板") · \(Self.ago(context.date.timeIntervalSince(record.at)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(record.text, forType: .string)
                withAnimation(Motion.pick(Motion.bounce)) { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { withAnimation { copied = false } }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(copied ? Color.green : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.borderless)
            .opacity(hovering || copied ? 1 : 0)
            .help("拷贝")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { hovering = $0 }
        .animation(Motion.pick(Motion.press), value: hovering)
    }

    static func ago(_ seconds: Double) -> String {
        seconds < 60 ? "刚刚" : seconds < 3600 ? "\(Int(seconds / 60)) 分钟前" : "\(Int(seconds / 3600)) 小时前"
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
        .animation(Motion.pick(Motion.bounce), value: text)
    }

    private var text: String {
        switch model.voiceState {
        case .armed: return "准备中"
        case .listening: return "正在听"
        case .transcribing: return "转写中"
        case .idle:
            if model.isPaused { return "已暂停" }
            return model.needsAttention ? "要处理" : "待命"
        }
    }

    private var color: Color {
        switch model.voiceState {
        case .armed, .listening: return Brand.coralBottom
        case .transcribing: return Brand.lavender
        case .idle:
            if model.isPaused { return .secondary }
            return model.needsAttention ? .orange : .secondary
        }
    }
}

/// 最上面一块「怎么说话」：左边一颗照 Logo 画的 ●（按住就能试），右边平时写「━ 长按 [确认键] 说话」；
/// 按住时 ● 外圈扩散、右边就地变成声波 + 计时，转写时 ● 变薰衣草色、闪着字行，出完字 ● 打勾、写贴到了哪。
struct TalkCard: View {
    @Environment(AppModel.self) private var model
    @State private var trying = false
    @State private var showsDone = false

    enum Phase: Equatable { case idle, noKey, paused, armed, listening, transcribing, done }

    private var phase: Phase {
        switch model.voiceState {
        case .armed: return .armed
        case .listening: return .listening
        case .transcribing: return .transcribing
        case .idle:
            if model.isPaused { return .paused }
            if showsDone { return .done }
            return model.talkKey == nil ? .noKey : .idle
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            TalkOrb(phase: phase, trying: $trying)
            ZStack(alignment: .leading) {
                content
                    .id(phase == .armed ? Phase.listening : phase)
                    .transition(.swapIn)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(tint.opacity(phase == .idle || phase == .noKey || phase == .paused ? 0.045 : 0.14)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(phase == .idle || phase == .noKey || phase == .paused ? Color.primary.opacity(0.08) : tint.opacity(0.35), lineWidth: 0.5))
        .animation(Motion.pick(Motion.bounce), value: phase)
        .onChange(of: model.lastInsertedAt) { _, new in
            guard new != nil else { return }
            showsDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { showsDone = false }
        }
    }

    private var tint: Color {
        switch phase {
        case .armed, .listening: return Brand.coralTop
        case .transcribing: return Brand.lavender
        case .done: return .tileGreen
        default: return .primary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            if let key = model.talkKey {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        GestureGlyph(gesture: key.gesture)
                        Text(key.gesture.title).font(.title3.weight(.semibold))
                        Button {
                            model.openSettings(.keys, focus: .init(editSpot: model.talkSpotID))
                        } label: {
                            KeyChip(name: key.keyName)
                        }
                        .buttonStyle(TileButtonStyle())
                        .help("改说话键")
                        Text(key.verb).font(.title3.weight(.semibold))
                    }
                    Text("松手后字贴到光标处 · 按住左边的 ● 也能试").font(.caption).foregroundStyle(.secondary)
                }
            }
        case .noKey:
            VStack(alignment: .leading, spacing: 5) {
                Text("还没设说话键").font(.headline)
                HStack(spacing: 8) {
                    Text("按住左边的 ● 先试一下").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("设一个") { model.openSettings(.keys) }
                        .prominentButton()
                        .controlSize(.small)
                }
            }
        case .paused:
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("已暂停监听").font(.headline)
                    Text("\(model.activeShortName ?? "遥控器")照常控制别的 App").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                Button("继续") { model.setPaused(false) }.prominentButton().controlSize(.small)
            }
        case .armed, .listening:
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 10) {
                    LevelWave(level: model.micLevel)
                        .frame(width: 96, height: 20)
                    if let since = model.talkStartedAt {
                        TimelineView(.periodic(from: since, by: 1)) { context in
                            Text(SpeechHUDView.clock(context.date.timeIntervalSince(since)))
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .foregroundStyle(Brand.coralText)
                                .contentTransition(.numericText())
                        }
                    }
                }
                if model.voiceState == .listening, !model.liveTranscript.isEmpty {
                    // 实时预览出了字：这一行换成说到现在的字，太长只留最后一截
                    Text(model.liveTranscript).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                } else {
                    Text(model.voiceState == .armed ? "按住别松，外圈走满就开始算" : (trying ? "松开出字" : (model.talkKey?.releaseHint ?? "说完出字")))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        case .transcribing:
            VStack(alignment: .leading, spacing: 6) {
                Text("正在转成字…").font(.headline)
                ShimmerLines().frame(width: 120, height: 14)
            }
        case .done:
            let record = model.recentTranscripts.first
            VStack(alignment: .leading, spacing: 3) {
                Text("已输入 \(record?.text.count ?? 0) 字 → \(record?.app ?? "剪贴板")").font(.headline).lineLimit(1)
                if let text = record?.text {
                    Text("「\(text)」").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
    }
}

/// 说话块左边的 ●：照 Logo 的按钮画（珊瑚色、底下有厚度），按住开麦说话、松手出字。
/// 准备中外圈按长按时间走满，正在听时一圈圈往外扩、跟着音量胀缩；转写中变薰衣草色，出完字打勾，暂停时是空心的。
struct TalkOrb: View {
    @Environment(AppModel.self) private var model
    let phase: TalkCard.Phase
    @Binding var trying: Bool
    @State private var hovering = false

    private let size: CGFloat = 38

    private var animated: Bool { (phase == .armed || phase == .listening) && !Motion.reduceMotion }
    private var pressable: Bool { phase == .idle || phase == .noKey || trying }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                if phase == .armed, let since = model.talkStartedAt {
                    let progress = min(1, max(0, context.date.timeIntervalSince(since) / max(model.config.timing.longPressThreshold, 0.05)))
                    Circle().stroke(Brand.coralTop.opacity(0.18), lineWidth: 3).frame(width: size + 10, height: size + 10)
                    Circle().trim(from: 0, to: progress)
                        .stroke(Brand.coralTop, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .frame(width: size + 10, height: size + 10)
                }
                if phase == .listening {
                    ForEach(0..<2, id: \.self) { index in
                        let p = ((t + Double(index) * 0.65).truncatingRemainder(dividingBy: 1.3)) / 1.3
                        Circle()
                            .stroke(Brand.coralTop.opacity(0.7 * (1 - p)), lineWidth: 2)
                            .frame(width: size + 22 * p, height: size + 22 * p)
                    }
                }
                orb
                    .scaleEffect(phase == .listening && !Motion.reduceMotion ? 1 + 0.08 * CGFloat(min(1, model.micLevel * 1.5)) : 1)
            }
            .frame(width: size + 16, height: size + 16)
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard pressable, !trying else { return }
                trying = true
                model.tryPress(true)
            }
            .onEnded { _ in
                guard trying else { return }
                trying = false
                model.tryPress(false)
            })
        .onHover { hovering = $0 }
        .help(pressable ? "按住说话，松开出字" : "")
        .accessibilityLabel("按住试一下")
    }

    @ViewBuilder
    private var orb: some View {
        let down = trying || phase == .armed || phase == .listening
        switch phase {
        case .paused:
            Circle().strokeBorder(Color.secondary.opacity(0.6), lineWidth: 2.5).frame(width: size, height: size)
                .overlay(Image(systemName: "pause.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.secondary))
        case .transcribing:
            Circle().fill(Brand.lavender).frame(width: size, height: size)
                .overlay(Image(systemName: "text.alignleft").font(.system(size: 14, weight: .bold)).foregroundStyle(.white))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
        case .done:
            Circle().fill(Color.tileGreen).frame(width: size, height: size)
                .overlay(Image(systemName: "checkmark").font(.system(size: 15, weight: .heavy)).foregroundStyle(.white))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        default:
            ZStack {
                // 厚度：底下一层深珊瑚色，按下去时顶面落到它的位置
                Circle().fill(HUDColors.coralDeep).frame(width: size, height: size).offset(y: 3)
                Circle().fill(Brand.coral).frame(width: size, height: size)
                    .overlay(Circle().fill(LinearGradient(colors: [.white.opacity(0.25), .clear], startPoint: .top, endPoint: .center)))
                    .overlay(Image(systemName: "mic.fill").font(.system(size: 14, weight: .bold)).foregroundStyle(.white.opacity(down ? 0.75 : 1)))
                    .offset(y: down ? 3 : (hovering && pressable ? -1 : 0))
            }
            .shadow(color: Brand.coralBottom.opacity(down ? 0.15 : 0.35), radius: down ? 2 : 6, y: down ? 1 : 3)
            .animation(Motion.press, value: down)
            .animation(Motion.pick(Motion.bounce), value: hovering)
        }
    }
}

/// 转写时闪着的字行（浮窗里那三行的小号）。
struct ShimmerLines: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                for (index, width) in [1.0, 0.72].enumerated() {
                    let p = (t - Double(index) * 0.14).truncatingRemainder(dividingBy: 1)
                    let fill = Motion.reduceMotion ? 1 : 0.15 + 0.85 * min(1, (p < 0 ? p + 1 : p) / 0.6)
                    let rect = CGRect(x: 0, y: Double(index) * 9 + 2, width: size.width * width * fill, height: 5)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(Brand.lavender.opacity(0.8)))
                }
            }
        }
    }
}

/// 手势的小图形：单击一个点、双击两个点、长按一条横杠（设计稿键位表的列头）。
struct GestureGlyph: View {
    let gesture: GestureKind
    /// 不传就是珊瑚色
    var tint: Color?

    private var style: AnyShapeStyle { tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(Brand.coral) }

    var body: some View {
        switch gesture {
        case .single: Circle().fill(style).frame(width: 7, height: 7)
        case .double: HStack(spacing: 2) { Circle().frame(width: 6, height: 6); Circle().frame(width: 6, height: 6) }.foregroundStyle(style)
        case .long: Capsule().fill(style).frame(width: 18, height: 6)
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

/// 面板里说话时的一排细竖条。
struct LevelWave: View {
    let level: Float

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            Canvas { canvas, size in
                let count = 12
                let gap = (size.width - 3.5 * Double(count)) / Double(count - 1)
                for index in 0..<count {
                    let wobble = 0.6 + 0.4 * sin(t * 10 + Double(index) * 1.3)
                    let h = max(3, size.height * min(1, (0.2 + Double(level) * 1.2) * wobble))
                    let rect = CGRect(x: Double(index) * (3.5 + gap), y: (size.height - h) / 2, width: 3.5, height: h)
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 1.75),
                                with: .linearGradient(Gradient(colors: [Brand.coralTop, Brand.coralBottom]),
                                                      startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: rect.maxY)))
                }
            }
        }
    }
}

/// 面板顶上的「要处理」提示条：缺权限时点「开启」直接打开系统设置和拖拽小窗，不先绕去设置窗口。
struct AttentionBanner: View {
    let attention: AppModel.Attention
    let fix: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            IconTile(symbol: attention.permission?.symbol ?? (attention.informational ? "mic.fill" : "exclamationmark"),
                     color: attention.permission?.tileColor ?? (attention.informational ? .tileBlue : .tileOrange), size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.title).font(.callout.weight(.semibold))
                Text(attention.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            // 只是告诉一声的不放按钮
            if !attention.informational {
                Button(attention.permission != nil ? "开启" : attention.retry ? "重试" : "去看看", action: fix)
                    .prominentButton()
                    .controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill((attention.informational ? Color.tileBlue : Color.tileOrange).opacity(0.12)))
    }
}
