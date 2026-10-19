import AppKit
import SwiftUI
import VoxPalmEngine

/// 第一次打开的引导：欢迎 → 打开 3 个权限 → 选控制设备和收音设备 → 设一个说话键并当场试一句。关掉后可以从「关于」里再打开。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State var step: Int
    let close: () -> Void
    @State private var learnedName: String?
    @State private var learnedAt: Date?

    static let size = NSSize(width: 620, height: 560)

    init(step: Int = 0, close: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.close = close
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: devices
                default: talkKey
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)
            footer
        }
        .padding(.horizontal, 40)
        .padding(.top, 58)
        .padding(.bottom, 28)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(BrandBackdrop())
        .overlay(alignment: .top) { progress.padding(.top, 19) }
        .tint(Brand.coralBottom)
        .animation(.spring(duration: 0.4), value: step)
    }

    // MARK: - 上面的进度和下面的按钮

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(0..<4, id: \.self) { index in
                Capsule()
                    .fill(index <= step ? AnyShapeStyle(Brand.coral) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: index == step ? 28 : 16, height: 5)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step > 0 {
                Button { step -= 1 } label: { Text("上一步").frame(minWidth: 56) }
                    .secondaryButton()
                    .controlSize(.large)
            }
            Spacer()
            switch step {
            case 0:
                Button { step = 1 } label: { Text("开始设置").frame(minWidth: 96) }
                    .prominentButton().controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            case 1:
                if !allGranted {
                    Button("稍后再开") { step = 2 }.buttonStyle(.plain).foregroundStyle(.secondary).padding(.trailing, 6)
                }
                Button { step = 2 } label: { Text("继续").frame(minWidth: 72) }
                    .prominentButton().controlSize(.large)
                    .disabled(!allGranted)
                    .keyboardShortcut(.defaultAction)
            case 2:
                Button { step = 3 } label: { Text("继续").frame(minWidth: 72) }
                    .prominentButton().controlSize(.large)
                    .disabled(model.config.controlDeviceIDs.isEmpty)
                    .keyboardShortcut(.defaultAction)
            default:
                Button {
                    model.cancelLearning()
                    model.finishOnboarding()
                    close()
                } label: { Text(learnedName == nil ? "以后再设" : "完成").frame(minWidth: 72) }
                    .prominentButton().controlSize(.large)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var allGranted: Bool {
        Permission.allCases.allSatisfy { model.permissions[$0] == true }
    }

    private func heading(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 26, weight: .bold))
            Text(subtitle).font(.title3).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 22)
    }

    // MARK: - 第 1 步：欢迎

    private var welcome: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            AppIconImage(size: 104)
                .shadow(color: Brand.coralBottom.opacity(0.35), radius: 24, y: 10)
                .padding(.bottom, 22)
            Text("按住说话，松手出字").font(.system(size: 30, weight: .bold))
                .padding(.bottom, 8)
            Text("把遥控器和无线麦，变成 Mac 的语音按钮。")
                .font(.title3).foregroundStyle(.secondary)
                .padding(.bottom, 30)
            HStack(spacing: 10) {
                FlowStep(tile: IconTile(symbol: "circle.fill", color: Brand.coralBottom, size: 30), title: "按住键", detail: "遥控器、无线麦")
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                FlowStep(tile: IconTile(symbol: "waveform", color: .tilePurple, size: 30), title: "说一句", detail: "本机转写")
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                FlowStep(tile: IconTile(symbol: "text.alignleft", color: .tileGreen, size: 30), title: "松手出字", detail: "贴到光标处")
            }
            Spacer(minLength: 0)
            Label("设置大约两分钟，按键和声音只在这台 Mac 上处理。", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 第 2 步：权限

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("打开 3 个权限", "点「开启」，把掌声拖进系统设置的列表里就行。")
            VStack(spacing: 10) {
                ForEach(Permission.allCases) { permission in
                    PermissionCard(permission: permission, granted: model.permissions[permission] == true)
                }
            }
            Spacer(minLength: 12)
            Label("掌声只读按键、只在你按住时录音，都在这台 Mac 上处理，不上传。", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.bottom, 18)
        }
    }

    // MARK: - 第 3 步：设备

    private var devices: some View {
        VStack(alignment: .leading, spacing: 0) {
            heading("用什么按，用什么收音", "两个可以不是同一台：用遥控器按键，用好一点的麦克风收音。")
            VStack(spacing: 10) {
                HStack(spacing: 14) {
                    IconTile(symbol: model.activeDevice.map(DevicesPane.icon(for:)) ?? "av.remote", color: .tileBlue, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("控制设备").font(.headline)
                        Text(model.activeDevice?.detail ?? "按哪台设备上的键").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Picker("控制设备", selection: Binding(get: { model.config.controlDeviceIDs.first ?? "" },
                                                     set: { model.selectControlDevice($0.isEmpty ? nil : $0) })) {
                        Text("还没选").tag("")
                        ForEach(model.devices) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                .padding(16)
                .cardBackground(cornerRadius: 16)

                HStack(spacing: 14) {
                    IconTile(symbol: model.selectedMic.map(DevicesPane.icon(for:)) ?? "mic.fill", color: .tileOrange, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("收音设备").font(.headline)
                        Text(model.selectedMic.map { "\($0.name) · \(Int($0.nominalSampleRate / 1000)) kHz" } ?? "用来录你说的话")
                            .font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Picker("收音设备", selection: model.binding(\.voice.micUID)) {
                        Text("跟随系统默认输入").tag(String?.none)
                        ForEach(model.micDevices) { Text($0.name).tag(Optional($0.uid)) }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                }
                .padding(16)
                .cardBackground(cornerRadius: 16)
            }
            Spacer(minLength: 12)
            HStack {
                Label("列表里没有？先在系统设置里连上蓝牙。", systemImage: "info.circle")
                    .font(.callout).foregroundStyle(.secondary)
                Button("刷新") { model.refreshDevices() }.buttonStyle(.link)
            }
            .padding(.bottom, 18)
        }
        .onAppear { model.refreshDevices() }
    }

    // MARK: - 第 4 步：说话键

    private var talkKey: some View {
        let reportsRelease = model.activeDevice?.reportsRelease ?? true
        return VStack(alignment: .leading, spacing: 0) {
            heading("设一个说话键", learnedName == nil
                    ? "按一下你想用来说话的键，比如遥控器的确认键、无线麦的录制键。"
                    : (reportsRelease ? "长按它就是按住说话，松手出字。" : "单击它开始说话，再单击一下出字。"))
            HStack {
                Spacer()
                KeyTarget(name: learnedName, listening: model.voiceState != .idle)
                Spacer()
            }
            .padding(.bottom, 18)
            if learnedName != nil {
                tryResult
            }
            Spacer(minLength: 0)
        }
        .onAppear(perform: learn)
    }

    /// 学到键以后：提示试一句，转出字了就把结果显示出来。
    @ViewBuilder
    private var tryResult: some View {
        let reportsRelease = model.activeDevice?.reportsRelease ?? true
        if let text = model.lastTranscript, let at = model.lastTranscriptAt, let learnedAt, at > learnedAt {
            HStack(alignment: .top, spacing: 12) {
                IconTile(symbol: "checkmark", color: .tileGreen, size: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("成了！转出来的字：").font(.headline)
                    Text(text).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .cardBackground(cornerRadius: 14, highlighted: .tileGreen)
        } else {
            HStack(spacing: 12) {
                IconTile(symbol: model.voiceState == .idle ? "mic.fill" : "waveform", color: Brand.coralBottom, size: 28)
                Text(model.voiceState == .idle
                     ? (reportsRelease ? "现在按住「\(learnedName ?? "")」，说一句试试。" : "现在单击「\(learnedName ?? "")」，说一句，再单击一下。")
                     : "正在听……说完松手")
                    .font(.callout.weight(.medium))
                Spacer(minLength: 0)
            }
            .padding(14)
            .cardBackground(cornerRadius: 14)
        }
    }

    private func learn() {
        guard learnedName == nil, model.activeDevice != nil else { return }
        let reportsRelease = model.activeDevice?.reportsRelease ?? true
        model.startLearning(spot: "+", purpose: "onboarding") { event in
            learnedName = event.label
            learnedAt = Date()
            model.setBinding(KeyBinding(button: event.button, buttonLabel: event.label,
                                        gesture: reportsRelease ? .long : .single,
                                        action: reportsRelease ? .pushToTalk : .toggleDictation))
        }
    }
}

/// 欢迎页上「按住键 → 说一句 → 松手出字」的一格。
private struct FlowStep: View {
    let tile: IconTile
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            tile
            VStack(spacing: 1) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 136, height: 112)
        .cardBackground(cornerRadius: 16)
    }
}

/// 说话键的大方块：没学到键时一圈珊瑚色的光在呼吸，学到了显示键名。
private struct KeyTarget: View {
    let name: String?
    let listening: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Brand.coralTop.opacity(name == nil ? (pulse ? 0.0 : 0.55) : 0), lineWidth: 10)
                .scaleEffect(pulse ? 1.12 : 1)
                .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .fill(.background)
                .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(name == nil ? AnyShapeStyle(Brand.coralTop.opacity(0.7)) : AnyShapeStyle(Brand.coral),
                                  style: StrokeStyle(lineWidth: name == nil ? 1.5 : 3, dash: name == nil ? [6, 5] : [])))
                .shadow(color: .black.opacity(0.08), radius: 10, y: 4)
            if let name {
                VStack(spacing: 10) {
                    Text(name).font(.system(size: 20, weight: .bold)).multilineTextAlignment(.center).lineLimit(2)
                        .padding(.horizontal, 10)
                    if listening {
                        LevelWave(level: 0.5).frame(width: 70, height: 18)
                    } else {
                        Capsule().fill(Brand.coral).frame(width: 26, height: 7)
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 26)).foregroundStyle(Brand.coralText)
                    Text("按一下\n设备上的键").font(.headline).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 168, height: 168)
        .onAppear { pulse = true }
    }
}

/// 一个权限一张卡：彩色图标、用途，右边是「开启」或「已开启」。引导和设置的权限页共用。
struct PermissionCard: View {
    let permission: Permission
    let granted: Bool

    var body: some View {
        HStack(spacing: 14) {
            IconTile(symbol: permission.symbol, color: permission.tileColor, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title).font(.headline)
                Text(permission.purpose).font(.callout).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if granted {
                StatusPill(text: "已开启", color: .tileGreen, symbol: "checkmark")
            } else {
                Button { permission.request() } label: { Text("开启").frame(minWidth: 36) }
                    .prominentButton()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardBackground(cornerRadius: 16, highlighted: granted ? .tileGreen : nil)
        .animation(.spring(duration: 0.3), value: granted)
    }
}
