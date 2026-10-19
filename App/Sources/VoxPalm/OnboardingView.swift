import AppKit
import SwiftUI
import VoxPalmEngine

/// 第一次打开的引导（design/VoxPalm-Motion.html「第一次打开」）：6 步，每步只做一件事，能自动判断的不让人点。
/// 欢迎 → 权限（一次一个）→ 用什么按（转盘，按一下实物就认出来）→ 用什么收音 → 说话键（图上亮着的键）→ 其余的键（可跳过）。
/// 点完成后窗口收进菜单栏图标。关掉后可以从「关于」或右键菜单里再打开。
struct OnboardingView: View {
    enum Step: Int, CaseIterable {
        case welcome, permissions, device, mic, talk, keys

        var title: String {
            switch self {
            case .welcome: return "欢迎"
            case .permissions: return "权限"
            case .device: return "用什么按"
            case .mic: return "用什么收音"
            case .talk: return "说话键"
            case .keys: return "其余的键"
            }
        }
    }

    @Environment(AppModel.self) private var model
    @State var step: Step
    @State private var direction: CGFloat = 1
    @State private var focusedDevice: PickerDevice?
    @State private var talkMapped = false
    @State private var autoAdvance: DispatchWorkItem?
    let finish: () -> Void

    static let size = NSSize(width: 780, height: 560)

    init(step: Step = .welcome, finish: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.finish = finish
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .offset(x: Motion.reduceMotion ? 0 : 44 * direction).combined(with: .opacity),
                        removal: .offset(x: Motion.reduceMotion ? 0 : -34 * direction).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            footer
        }
        .padding(.horizontal, 44)
        .padding(.top, 58)
        .padding(.bottom, 24)
        .frame(width: Self.size.width, height: Self.size.height)
        .background(BrandBackdrop())
        .overlay(alignment: .top) { progress.padding(.top, 22) }
        .tint(Brand.coralBottom)
        .onChange(of: allGranted) { _, granted in
            // 权限都开了，自己往下走
            guard granted, step == .permissions else { return }
            let work = DispatchWorkItem { if step == .permissions { go(.device) } }
            autoAdvance = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.1, execute: work)
        }
    }

    private func go(_ target: Step) {
        autoAdvance?.cancel()
        direction = target.rawValue >= step.rawValue ? 1 : -1
        withAnimation(Motion.pick(Motion.smooth)) { step = target }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: WelcomeStep()
        case .permissions: PermissionsStep()
        case .device: DeviceStep(focused: $focusedDevice)
        case .mic: MicStep()
        case .talk: TalkKeyStep(mapped: $talkMapped)
        case .keys: OtherKeysStep()
        }
    }

    // MARK: - 上面的进度和下面的按钮

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { item in
                Capsule()
                    .fill(item.rawValue < step.rawValue ? AnyShapeStyle(Brand.coralTop.opacity(0.55))
                          : item == step ? AnyShapeStyle(Brand.coralBottom) : AnyShapeStyle(Color.primary.opacity(0.12)))
                    .frame(width: item == step ? 32 : 16, height: 5)
                    .onTapGesture { go(item) }
                    .help(item.title)
            }
        }
        .animation(Motion.pick(Motion.bounce), value: step)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if step != .welcome {
                Button { go(Step(rawValue: step.rawValue - 1) ?? .welcome) } label: { Text("上一步").frame(minWidth: 56) }
                    .secondaryButton()
                    .controlSize(.large)
            }
            Spacer()
            if let ghost = ghostTitle {
                Button(ghost) { next() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 6)
            }
            Button { next() } label: {
                Text(nextTitle).frame(minWidth: 72).contentTransition(.opacity)
            }
            .prominentButton()
            .controlSize(.large)
            .disabled(nextDisabled)
            .keyboardShortcut(.defaultAction)
            .animation(Motion.pick(Motion.bounce), value: nextTitle)
        }
        .padding(.top, 14)
    }

    private var allGranted: Bool {
        Permission.allCases.allSatisfy { model.permissions[$0] == true }
    }

    private var nextTitle: String {
        switch step {
        case .welcome: return "开始设置"
        case .device:
            if let focused = focusedDevice, !focused.connected { return "先连上它" }
            return model.activeShortName.map { "用「\($0)」" } ?? "继续"
        case .mic:
            let mic = model.pickerMics.first { $0.uid == model.config.voice.micUID } ?? model.pickerMics.first
            return mic.map { "用「\($0.shortName)」" } ?? "继续"
        case .keys: return "完成"
        default: return "继续"
        }
    }

    private var ghostTitle: String? {
        switch step {
        case .permissions: return allGranted ? nil : "稍后再开"
        case .talk: return talkMapped ? nil : "以后再设"
        default: return nil
        }
    }

    private var nextDisabled: Bool {
        switch step {
        case .permissions: return !allGranted
        case .device: return model.config.controlDeviceIDs.isEmpty || focusedDevice?.connected == false
        case .talk: return !talkMapped
        default: return false
        }
    }

    private func next() {
        guard let target = Step(rawValue: step.rawValue + 1) else {
            model.cancelLearning()
            model.finishOnboarding()
            finish()
            return
        }
        model.cancelLearning()
        go(target)
    }
}

/// 每一步的大标题和一句说明。
private struct StepHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 25, weight: .bold))
            Text(subtitle).font(.system(size: 14.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 18)
        .staggerIn(0)
    }
}

// MARK: - 第 1 步：欢迎

private struct WelcomeStep: View {
    @State private var held = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LogoMark(size: 148, held: held)
                .padding(.bottom, 14)
                .staggerIn(0, dy: 0)
            Label("按住 Logo（或空格）试试", systemImage: "hand.point.up.left")
                .font(.caption).foregroundStyle(.tertiary)
                .padding(.bottom, 22)
                .staggerIn(1)
            Text("按住说话，松手出字").font(.system(size: 31, weight: .bold))
                .padding(.bottom, 8)
                .staggerIn(2)
            Text("把遥控器和无线麦，变成 Mac 的语音按钮。")
                .font(.system(size: 15.5)).foregroundStyle(.secondary)
                .staggerIn(3)
            Spacer(minLength: 0)
            Label("设置大约两分钟。按键和声音只在这台 Mac 上处理。", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
                .staggerIn(4)
        }
        .frame(maxWidth: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.space, phases: [.down, .up]) { press in
            held = press.phase == .down
            return .handled
        }
        .onAppear { focused = true }
    }
}

// MARK: - 第 2 步：权限

private struct PermissionsStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "打开 3 个权限", subtitle: "一次一个：点「开启」，把掌声拖进系统设置的列表里。")
            PermissionStack(expandsCurrent: true)
                .staggerIn(1)
            Spacer(minLength: 8)
            Label("掌声只读按键、只在你按住时录音，都在这台 Mac 上处理，不上传。", systemImage: "lock.fill")
                .font(.callout).foregroundStyle(.secondary)
                .staggerIn(2)
        }
    }
}

/// 三个权限一张一张来：还没开的第一张展开，带拖拽小动画和「为什么要它」；开了的收成一行打勾。引导和设置的权限页共用。
struct PermissionStack: View {
    @Environment(AppModel.self) private var model
    var expandsCurrent = true

    var body: some View {
        let current = Permission.allCases.first { model.permissions[$0] != true }
        VStack(spacing: 10) {
            ForEach(Permission.allCases) { permission in
                PermissionCard(permission: permission, granted: model.permissions[permission] == true,
                               expanded: expandsCurrent && permission == current, isCurrent: permission == current)
            }
        }
        .animation(Motion.pick(Motion.smooth), value: model.permissions)
    }
}

/// 一个权限一张卡：彩色图标、用途，右边是「开启」或「已开启」；展开时多一块小动画和说明。
struct PermissionCard: View {
    let permission: Permission
    let granted: Bool
    var expanded = false
    var isCurrent = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: permission.symbol, color: permission.tileColor, size: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.title).font(.headline)
                    Text(permission.purpose).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if granted {
                    StatusPill(text: "已开启", color: .tileGreen, symbol: "checkmark")
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                } else if isCurrent {
                    Button { permission.request() } label: { Text("开启").frame(minWidth: 36) }
                        .prominentButton()
                } else {
                    Button { permission.request() } label: { Text("开启").frame(minWidth: 36) }
                        .secondaryButton()
                }
            }
            if expanded {
                HStack(alignment: .center, spacing: 16) {
                    Group {
                        if permission == .microphone { MicPromptIllustration() } else { DragIllustration() }
                    }
                    .frame(width: 150, height: 84)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(permission.consequence).font(.callout.weight(.semibold))
                        Text(permission == .microphone ? "点「开启」，系统会直接问你，选「允许」就行。"
                             : "点「开启」会打开系统设置，下面浮出掌声的图标，按住拖进列表就行。")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.leading, 52)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .cardBackground(cornerRadius: 16, highlighted: granted ? .tileGreen : (expanded ? Brand.coralBottom : nil))
        .animation(Motion.pick(Motion.bounce), value: granted)
    }
}

/// 小动画：掌声的图标从下面飞进系统设置的列表，列表里多一行打开的开关。
private struct DragIllustration: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let p = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.6) / 2.6
            let move = min(1, max(0, (p - 0.15) / 0.4))
            let eased = 1 - pow(1 - move, 3)
            let arrived = p > 0.58
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.background)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                VStack(spacing: 0) {
                    row("终端", on: true)
                    row("脚本编辑器", on: false)
                    row("掌声", on: true, logo: true).opacity(arrived ? 1 : 0)
                }
                HStack(spacing: 4) {
                    AppIconImage(size: 14)
                    Text("掌声").font(.system(size: 9, weight: .semibold))
                }
                .padding(.horizontal, 5).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.background).shadow(color: .black.opacity(0.25), radius: 4, y: 2))
                .offset(x: 62 - 50 * eased, y: 58 - 40 * eased)
                .opacity(p < 0.12 || arrived ? 0 : 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func row(_ name: String, on: Bool, logo: Bool = false) -> some View {
        HStack(spacing: 5) {
            if logo { AppIconImage(size: 9) } else { RoundedRectangle(cornerRadius: 2.5).fill(Color.secondary.opacity(0.5)).frame(width: 9, height: 9) }
            Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
            Spacer()
            Capsule().fill(on ? Color.green : Color.secondary.opacity(0.4)).frame(width: 14, height: 8)
        }
        .padding(.horizontal, 7)
        .frame(height: 18)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 0.5) }
    }
}

/// 小动画：系统弹框问麦克风，「允许」一闪一闪。
private struct MicPromptIllustration: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { context in
            let glow = 0.6 + 0.4 * sin(context.date.timeIntervalSinceReferenceDate * 3)
            VStack(spacing: 4) {
                AppIconImage(size: 18)
                Text("“掌声”想访问麦克风").font(.system(size: 9, weight: .semibold))
                HStack(spacing: 4) {
                    Text("不允许").font(.system(size: 8.5)).padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.08)))
                    Text("允许").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.white).padding(.horizontal, 9).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.tileBlue.opacity(glow)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - 第 3 步：用什么按

private struct DeviceStep: View {
    @Binding var focused: PickerDevice?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "用什么按", subtitle: "拿起想用的设备，随便按一个键，我们就认出来。也可以左右滑，或者在右边点。")
            ControlDevicePicker(identifies: true, stageWidth: 330, onFocus: { focused = $0 })
                .staggerIn(1)
        }
    }
}

// MARK: - 第 4 步：用什么收音

private struct MicStep: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "用什么收音", subtitle: "可以和按键的不是同一台。对着麦说句话，外面一圈圈的光会跟着跳。")
            MicPicker(stageWidth: 330)
                .staggerIn(1)
        }
    }
}

// MARK: - 第 5 步：说话键

/// 示意图上点亮建议的键，按一下实物就对上；接着按住它说一句，字直接贴进下面的试写区（顺便验证贴字这条路是通的）。
private struct TalkKeyStep: View {
    @Environment(AppModel.self) private var model
    @Binding var mapped: Bool
    @State private var spot: String?
    @State private var tryText = ""
    @State private var succeeded = false
    @State private var enteredAt = Date()
    @FocusState private var tryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let device = model.activeDevice {
                let resolved = model.diagram(for: device)
                StepHeading(title: "设一个说话键", subtitle: resolved.reportsRelease ? "以后按住它说话，松手出字。" : "这台设备读不到松开：按一下开始说话，再按一下出字。")
                HStack(alignment: .top, spacing: 24) {
                    stage(device: device, resolved: resolved)
                        .frame(width: 300)
                    side(resolved: resolved)
                }
                .staggerIn(1)
                .onAppear { start(device: device, resolved: resolved) }
                .onDisappear { model.cancelLearning() }
            } else {
                StepHeading(title: "设一个说话键", subtitle: "先回上一步选一个控制设备。")
            }
        }
        .onChange(of: model.lastInsertedAt) { _, new in
            guard mapped, let new, new > enteredAt else { return }
            withAnimation(Motion.pick(Motion.bounce)) { succeeded = true }
        }
    }

    private func spotName(_ resolved: AppModel.ResolvedDiagram) -> String {
        resolved.diagram.spots.first { $0.id == spot }?.name.replacingOccurrences(of: #"（.*）"#, with: "", options: .regularExpression) ?? "这个键"
    }

    private func stage(device: ControlDevice, resolved: AppModel.ResolvedDiagram) -> some View {
        var highlighted: [String: DeviceArt.Highlight] = [:]
        for (id, button) in resolved.buttons where model.pressedButtons.contains(button) { highlighted[id] = .pressed }
        if mapped, let spot, highlighted[spot] == nil { highlighted[spot] = .selected }
        return VStack(spacing: 6) {
            DeviceFigure(diagram: resolved.diagram, highlighted: highlighted, lit: mapped ? nil : spot) { tapped in
                guard tapped != spot || mapped else { return }
                withAnimation(Motion.pick(Motion.bounce)) {
                    spot = tapped
                    mapped = false
                    succeeded = false
                }
                learn(device: device)
            }
            .shadow(color: .black.opacity(0.22), radius: 10, y: 8)
            .padding(.vertical, 18)
            .padding(.horizontal, 18)
            .frame(maxHeight: .infinity)
            Text(model.activePickerDevice?.name ?? device.name).font(.system(size: 17, weight: .bold)).lineLimit(1)
            Text(resolved.diagram.spots.isEmpty ? "按到的键会加到图上" : "点图上别的键可以换一个").font(.caption).foregroundStyle(.secondary)
                .padding(.bottom, 14)
        }
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
    }

    @ViewBuilder
    private func side(resolved: AppModel.ResolvedDiagram) -> some View {
        let gestureLine = HStack(spacing: 7) {
            GestureGlyph(gesture: resolved.reportsRelease ? .long : .single)
            Text(resolved.reportsRelease ? "长按 = 按住说话，松手出字" : "单击开始，再单击出字")
        }
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
        VStack(alignment: .leading, spacing: 12) {
            if !mapped {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill").font(.title3).foregroundStyle(Brand.coralText)
                    (spot == nil
                        ? Text("按一下实物上你想用来说话的键").bold() + Text("，就对上了。")
                        : Text("建议用图上亮着的「\(spotName(resolved))」。\n") + Text("按一下实物上的这个键").bold() + Text("，就对上了。\n想用别的键？直接点图上的那个键。"))
                        .font(.callout)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardBackground(cornerRadius: 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
                gestureLine
            } else {
                HStack(spacing: 8) {
                    IconTile(symbol: "checkmark", color: .tileGreen, size: 24)
                    Text("对上了").font(.title3.weight(.semibold))
                    KeyChip(name: spotName(resolved))
                }
                .transition(.scale(scale: 0.9, anchor: .leading).combined(with: .opacity))
                gestureLine
                Text(succeeded ? "再说一句也行。" : (resolved.reportsRelease ? "现在按住「\(spotName(resolved))」说一句，字会贴进下面这个框：" : "现在按一下「\(spotName(resolved))」说一句，再按一下："))
                    .font(.callout).foregroundStyle(.secondary)
                TextField("试写区：说的话会贴到这里", text: $tryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .lineLimit(3...4)
                    .focused($tryFocused)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.7)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(tryFocused ? Brand.coralTop.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: tryFocused ? 2 : 0.5))
                if succeeded {
                    HStack(alignment: .top, spacing: 10) {
                        IconTile(symbol: "checkmark", color: .tileGreen, size: 22)
                        (Text("成了！").bold() + Text("以后在任何 App 里都这样：光标在哪，字就贴到哪。屏幕下方的浮窗会告诉你在听、在转、贴到了哪。"))
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.tileGreen.opacity(0.1)))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            Spacer(minLength: 0)
        }
        .animation(Motion.pick(Motion.bounce), value: mapped)
    }

    private func start(device: ControlDevice, resolved: AppModel.ResolvedDiagram) {
        enteredAt = Date()
        if spot == nil {
            spot = model.talkSpotID ?? resolved.diagram.recommendedTalkSpot?.id
            // 已经设过说话键（比如从后面退回来），直接算对上了
            if model.talkSpotID != nil, model.talkKey != nil {
                mapped = true
                tryFocused = true
                return
            }
        }
        if !mapped { learn(device: device) }
    }

    /// 等用户按一下实物：按到的键记成图上亮着的位置，设成说话键。
    /// 通用外形的键位就是学过的键，按到哪个就把哪个加到图上（一个键都没学过时也能学）。
    private func learn(device: ControlDevice) {
        let generic = model.diagram(for: device).diagram.id == "generic"
        guard let target = generic ? "+" : spot else { return }
        model.startLearning(spot: target, purpose: "onboarding") { event in
            let resolved = model.diagram(for: device)
            // 按到的是图上已知的另一个键（媒体键这类键值已知的设备），就用那个位置
            let actual = resolved.buttons.first { $0.value == event.button }?.key ?? target
            let name = resolved.diagram.spots.first { $0.id == actual }?.name ?? event.label
            for binding in model.config.keyMap.bindings where binding.action.isVoice && binding.button != event.button {
                model.removeBinding(binding.id)
            }
            model.setBinding(KeyBinding(button: event.button, buttonLabel: name,
                                        gesture: resolved.reportsRelease ? .long : .single,
                                        action: resolved.reportsRelease ? .pushToTalk : .toggleDictation))
            withAnimation(Motion.pick(Motion.bounce)) {
                spot = actual
                mapped = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { tryFocused = true }
        }
    }
}

// MARK: - 第 6 步：其余的键

/// 套一个现成的用法：选「AI 编程」后，亮着的键依次按一下就对上，引线一条条画出来。键值已知的设备不用按。
private struct OtherKeysStep: View {
    @Environment(AppModel.self) private var model
    @State private var mode: Mode?
    @State private var queue: [String] = []
    @State private var current: String?
    @State private var mappedCount = 0

    enum Mode { case ai, talkOnly }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StepHeading(title: "其余的键也用上？", subtitle: "套一个现成的用法，亮着的键依次按一下就对上了。以后在设置 › 按键 里随时改。")
            if let device = model.activeDevice {
                let resolved = model.diagram(for: device)
                HStack(alignment: .top, spacing: 22) {
                    diagram(resolved)
                        .frame(width: 400)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.03)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
                    VStack(alignment: .leading, spacing: 8) {
                        presetButton(.ai, title: "AI 编程", detail: aiDescription(resolved), symbol: "sparkle", color: .tilePurple,
                                     enabled: !aiSpots(resolved).isEmpty) { startAI(device: device) }
                        presetButton(.talkOnly, title: "先只用说话键", detail: "其余的键照常控制别的 App", symbol: "mic.fill", color: .tileGray, enabled: true) {
                            model.cancelLearning()
                            withAnimation(Motion.pick(Motion.bounce)) { mode = .talkOnly; current = nil; queue = [] }
                        }
                        sequence(resolved)
                        Spacer(minLength: 0)
                    }
                }
                .staggerIn(1)
                .onDisappear { model.cancelLearning() }
            }
        }
    }

    private func diagram(_ resolved: AppModel.ResolvedDiagram) -> some View {
        let callouts = DiagramCallout.make(diagram: resolved.diagram, buttons: resolved.buttons, keyMap: model.config.keyMap,
                                           reportsRelease: resolved.reportsRelease, learning: nil)
            .filter { $0.isBound && $0.lines != ["点一下设置"] }
        var highlighted: [String: DeviceArt.Highlight] = [:]
        for (id, button) in resolved.buttons where model.pressedButtons.contains(button) { highlighted[id] = .pressed }
        return ZStack {
            DeviceDiagramView(diagram: resolved.diagram, callouts: callouts, pressed: model.pressedButtons, buttons: resolved.buttons,
                              selected: current, onSelect: { _ in })
                .animation(Motion.pick(Motion.smooth), value: callouts.map(\.id))
            if let current {
                // 亮着的键：盖一层只画这个键的光圈
                GeometryReader { geometry in
                    let layout = DiagramLayout(diagram: resolved.diagram, callouts: callouts, size: geometry.size)
                    if let spot = resolved.diagram.spots.first(where: { $0.id == current }) {
                        LitRing(frame: layout.frame(spot.box), isCircle: spot.shape == .circle)
                    }
                }
                .frame(height: DiagramLayout.preferredHeight(diagram: resolved.diagram, callouts: callouts))
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity)
    }

    private func presetButton(_ which: Mode, title: String, detail: String, symbol: String, color: Color, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                IconTile(symbol: symbol, color: color, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(mode == which ? Brand.coralTop.opacity(0.15) : Color.primary.opacity(0.045)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(mode == which ? Brand.coralTop.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: mode == which ? 1.5 : 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    @ViewBuilder
    private func sequence(_ resolved: AppModel.ResolvedDiagram) -> some View {
        if let current, let spot = resolved.diagram.spots.first(where: { $0.id == current }) {
            HStack(spacing: 8) {
                Text("按一下亮着的")
                KeyChip(name: spot.name)
                Spacer()
                Text("\(mappedCount + 1) / \(mappedCount + queue.count + 1)").monospacedDigit().fontWeight(.bold)
                Button("跳过") { advance(resolved) }.buttonStyle(.borderless)
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Brand.coralText)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Brand.coralTop.opacity(0.12)))
            .transition(.opacity.combined(with: .move(edge: .top)))
        } else if mode == .ai {
            Label("对上了 \(mappedCount) 个键。以后在设置 › 按键 里随时改。", systemImage: "checkmark.circle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(Color.tileGreen)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Color.tileGreen.opacity(0.1)))
                .transition(.opacity)
        } else if mode == .talkOnly {
            Text("好，其余的键不动，照常控制别的 App。").font(.callout).foregroundStyle(.secondary)
        }
    }

    /// 预设里这台设备有的键（说话键自己的长按已经设好，不再排进来）
    private func aiSpots(_ resolved: AppModel.ResolvedDiagram) -> [String] {
        var spots: [String] = []
        for item in AIPreset.items where resolved.diagram.spots.contains(where: { $0.id == item.spot }) && !spots.contains(item.spot) {
            if resolved.diagram.id != DeviceDiagram.footPedal.id && ["left", "right"].contains(item.spot) { continue }
            if !resolved.reportsRelease && AIPreset.items.filter({ $0.spot == item.spot }).allSatisfy({ $0.gesture == .long }) { continue }
            spots.append(item.spot)
        }
        return spots
    }

    private func aiDescription(_ resolved: AppModel.ResolvedDiagram) -> String {
        let spots = aiSpots(resolved)
        guard !spots.isEmpty else { return "这台设备键太少，用说话键就够了" }
        let names = spots.prefix(4).compactMap { id in resolved.diagram.spots.first { $0.id == id }?.name }
        return "给 Claude Code / Codex 用：切对话、发送、打开 App。会用到 " + names.joined(separator: "、") + (spots.count > 4 ? " 等" : "")
    }

    private func startAI(device: ControlDevice) {
        let resolved = model.diagram(for: device)
        withAnimation(Motion.pick(Motion.bounce)) {
            mode = .ai
            mappedCount = 0
            queue = aiSpots(resolved)
        }
        advance(resolved)
    }

    /// 下一个键：键值已知就直接设上（隔一会儿，看得见引线一条条出来），不知道就点亮等用户按。
    private func advance(_ resolved: AppModel.ResolvedDiagram) {
        model.cancelLearning()
        guard let device = model.activeDevice else { return }
        guard !queue.isEmpty else {
            withAnimation(Motion.pick(Motion.bounce)) { current = nil }
            return
        }
        let spot = queue.removeFirst()
        withAnimation(Motion.pick(Motion.bounce)) { current = spot }
        if resolved.buttons[spot] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { apply(spot: spot, device: device) }
        } else {
            model.startLearning(spot: spot, purpose: "onboarding") { _ in apply(spot: spot, device: device) }
        }
    }

    private func apply(spot: String, device: ControlDevice) {
        let resolved = model.diagram(for: device)
        let bindings = AIPreset.bindings(for: resolved).filter { binding in
            resolved.buttons[spot] == binding.button && !(binding.gesture == .long && binding.action == .pushToTalk && model.talkKey?.button == binding.button)
        }
        withAnimation(Motion.pick(Motion.smooth)) {
            for binding in bindings { model.setBinding(binding) }
            mappedCount += 1
        }
        advance(resolved)
    }
}
