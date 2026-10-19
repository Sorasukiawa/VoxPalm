import AppKit
import SwiftUI
import VoxPalmEngine
import VoxPalmVoice

/// 点菜单栏图标弹出的面板（design/VoxPalm-Motion.html「日常使用」）：
/// 上面一块「怎么说话」，按住时就地变成声波 + 计时；控制、收音两块磁贴点开就地换设备；最近出的字可以拷贝。
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @State private var expanded: Tile?

    enum Tile { case control, mic }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let attention = model.attentions.first {
                AttentionBanner(attention: attention) {
                    if let permission = attention.permission {
                        model.closePanel()
                        permission.request()
                    } else {
                        model.openSettings(attention.fix)
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            TalkCard()
            switch expanded {
            case .control: ControlSwitcher(close: collapse)
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            case .mic: MicSwitcher(close: collapse)
                .transition(.scale(scale: 0.96, anchor: .top).combined(with: .opacity))
            case nil:
                tiles.transition(.opacity)
                outputRow
            }
            RecentList()
            footer
        }
        .padding(14)
        .frame(width: 340)
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
        HStack(spacing: 8) {
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
                let mic = model.pickerMics.first { $0.uid == model.config.voice.micUID } ?? model.pickerMics.first
                DeviceTile(label: "收音", name: mic?.shortName ?? "系统默认输入", art: mic?.art ?? PickerArt.system) {
                    HStack(spacing: 6) {
                        LevelBars(level: model.micLevel, live: model.voiceState == .listening || model.voiceState == .armed)
                        Spacer(minLength: 0)
                        if let selected = model.selectedMic {
                            Chip(text: "\(Int(selected.nominalSampleRate / 1000)) kHz", warn: selected.isLowRateBluetoothInput)
                        }
                    }
                }
            }
            .buttonStyle(TileButtonStyle())
            .help("点开换收音设备")
        }
    }

    private var outputRow: some View {
        Button { model.openSettings(.voice) } label: {
            HStack(spacing: 9) {
                IconTile(symbol: "text.alignleft", color: .tileGreen, size: 22)
                Text("出字：\(model.outputSummary)").font(.callout.weight(.medium)).lineLimit(1)
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Toggle("监听", isOn: Binding(get: { !model.isPaused }, set: { model.setPaused(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("关掉后掌声不读按键，遥控器照常控制别的 App（也可以按住 ⌥ 点菜单栏图标）")
            Spacer()
            Button("设置…") { model.openSettings() }
                .secondaryButton()
                .controlSize(.small)
            Button("退出") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .font(.callout)
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
            status()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// 收音磁贴点开后：麦克风列表，选中的那个在跳音量。
struct MicSwitcher: View {
    @Environment(AppModel.self) private var model
    let close: () -> Void
    @State private var meter = MicMeter()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            SwitcherHeader(title: "收音设备", link: "收音设置…", open: { model.openSettings(.devices, focus: .init(showsMics: true)) }, close: close)
            ForEach(model.pickerMics) { mic in
                let selected = model.config.voice.micUID == mic.uid
                Button {
                    model.update { $0.voice.micUID = mic.uid }
                    meter.start(uid: mic.uid, after: 0.3)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: close)
                } label: {
                    PickerRow(art: mic.art, title: mic.name, detail: mic.detail + (mic.warning == nil ? "" : " · 通话音质"), selected: selected,
                              trailing: selected ? AnyView(LevelBars(level: meter.level, live: true)) : nil)
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
        .onAppear { meter.start(uid: model.config.voice.micUID, after: 0.3) }
        .onDisappear { meter.stop() }
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
                    Text("最近出字")
                    Spacer()
                    Text("只记在这次运行里")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
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
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.primary.opacity(hovering ? 0.05 : 0)))
        .onHover { hovering = $0 }
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

/// 最上面一块「怎么说话」：平时写「━ 长按 [确认键] 说话」；按住时就地变成声波 + 计时，转写时闪着字行，出完字写贴到了哪。
struct TalkCard: View {
    @Environment(AppModel.self) private var model
    @State private var trying = false
    @State private var showsDone = false

    var body: some View {
        Group {
            if model.isPaused && model.voiceState == .idle {
                paused
            } else {
                switch model.voiceState {
                case .armed, .listening: recording
                case .transcribing: transcribing
                case .idle: showsDone ? AnyView(done) : AnyView(idle)
                }
            }
        }
        .transition(.opacity)
        .animation(Motion.pick(Motion.bounce), value: model.voiceState)
        .animation(Motion.pick(Motion.bounce), value: showsDone)
        .onChange(of: model.lastInsertedAt) { _, new in
            guard new != nil else { return }
            showsDone = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { showsDone = false }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(Brand.coral).frame(width: 14, height: 14)
                    .shadow(color: HUDColors.coralDeep, radius: 0, y: 2)
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
            Text(model.voiceState == .armed ? "按住别松，外圈走满就开始算" : (trying ? "松开按钮出字" : (model.talkKey?.releaseHint ?? "说完出字")))
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Brand.coralTop.opacity(0.16)))
    }

    private var transcribing: some View {
        HStack(spacing: 10) {
            ShimmerLines().frame(width: 92, height: 18)
            Text("正在转成字…").font(.callout.weight(.semibold))
            Spacer()
        }
        .padding(12)
        .cardBackground(cornerRadius: 14)
    }

    private var done: some View {
        let record = model.recentTranscripts.first
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.tileGreen)
                    .symbolEffect(.bounce, value: showsDone)
                Text("已输入 \(record?.text.count ?? 0) 字 → \(record?.app ?? "剪贴板")").font(.callout.weight(.semibold)).lineLimit(1)
            }
            if let text = record?.text {
                Text("「\(text)」").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.tileGreen.opacity(0.11)))
    }

    private var paused: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("已暂停监听").font(.title3.weight(.semibold))
            Text("掌声不读按键，\(model.activeShortName ?? "遥控器")照常控制别的 App。").font(.caption).foregroundStyle(.secondary)
            Button("继续监听") { model.setPaused(false) }.prominentButton().controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground(cornerRadius: 14)
    }

    private var idle: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let key = model.talkKey {
                HStack(spacing: 6) {
                    GestureGlyph(gesture: key.gesture)
                    Text(key.gesture.title).font(.title3.weight(.semibold))
                    Button {
                        model.openSettings(.keys, focus: .init(editSpot: model.talkSpotID))
                    } label: {
                        KeyChip(name: key.keyName)
                    }
                    .buttonStyle(.plain)
                    .help("改说话键")
                    Text(key.verb).font(.title3.weight(.semibold))
                }
                Text("\(model.activeShortName ?? "控制设备") · 松手后字贴到光标处").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("还没设说话键").font(.headline)
                Text("在「按键」里把一个键的长按设成「按住说话」。").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                PressToTalkButton(trying: $trying)
                if model.talkKey == nil {
                    Button("设一个说话键") { model.openSettings(.keys) }
                        .secondaryButton()
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .cardBackground(cornerRadius: 14)
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
                    canvas.fill(Path(roundedRect: rect, cornerRadius: 2.5), with: .color(Color(red: 0.38, green: 0.35, blue: 0.65).opacity(0.7)))
                }
            }
        }
    }
}

/// 「按住试一下」：按下开麦，松手出字。
struct PressToTalkButton: View {
    @Environment(AppModel.self) private var model
    @Binding var trying: Bool

    var body: some View {
        Label("按住试一下", systemImage: "mic.fill")
            .font(.callout.weight(.medium))
            .foregroundStyle(trying ? .white : Brand.coralText)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(trying ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(Brand.coralTop.opacity(0.14))))
            .overlay(Capsule().strokeBorder(Brand.coralTop.opacity(trying ? 0 : 0.35), lineWidth: 0.5))
            .scaleEffect(trying ? 0.97 : 1)
            .animation(Motion.press, value: trying)
            .contentShape(Capsule())
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

/// 麦克风旁边的四根小电平条。
struct LevelBars: View {
    let level: Float
    let live: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                let threshold = Float(index) / 4
                RoundedRectangle(cornerRadius: 1)
                    .fill(live && level > threshold ? Brand.coralTop : Color.secondary.opacity(0.35))
                    .frame(width: 3, height: CGFloat(5 + index * 3))
            }
        }
        .frame(height: 14, alignment: .bottom)
        .animation(.linear(duration: 0.08), value: level)
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
            IconTile(symbol: attention.permission?.symbol ?? "exclamationmark", color: attention.permission?.tileColor ?? .tileOrange, size: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(attention.title).font(.callout.weight(.semibold))
                Text(attention.detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(attention.permission == nil ? "去看看" : "开启", action: fix)
                .prominentButton()
                .controlSize(.small)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tileOrange.opacity(0.12)))
    }
}
