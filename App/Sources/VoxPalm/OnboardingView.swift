import AppKit
import SwiftUI
import VoxPalmEngine

/// 第一次打开的引导：欢迎 → 打开 3 个权限 → 选控制设备和收音设备 → 设一个说话键并当场试一句。关掉后可以从「关于」里再打开。
struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State var step: Int
    let close: () -> Void
    @State private var learnedName: String?

    init(step: Int = 0, close: @escaping () -> Void) {
        _step = State(initialValue: step)
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permissions
                case 2: devices
                default: talkKey
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack {
                HStack(spacing: 5) {
                    ForEach(0..<4, id: \.self) { index in
                        Capsule().fill(index == step ? Brand.coralTop : Color.secondary.opacity(0.35))
                            .frame(width: index == step ? 20 : 6, height: 6)
                    }
                }
                Spacer()
                if step > 0 { Button("上一步") { step -= 1 }.buttonStyle(.borderless) }
                primaryButton
            }
        }
        .padding(28)
        .frame(width: 480, height: 400)
        .tint(Brand.coralBottom)
    }

    @ViewBuilder
    private var primaryButton: some View {
        switch step {
        case 0:
            Button("开始设置") { step = 1 }.buttonStyle(.borderedProminent)
        case 1:
            let ready = model.permissions[.inputMonitoring] == true && model.permissions[.accessibility] == true
            Button(ready ? "继续" : "先跳过") { step = 2 }.buttonStyle(.borderedProminent).tint(ready ? Brand.coralBottom : .gray)
        case 2:
            Button("继续") { step = 3 }.buttonStyle(.borderedProminent).disabled(model.config.controlDeviceIDs.isEmpty)
        default:
            Button("完成") {
                model.cancelLearning()
                model.finishOnboarding()
                close()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            if let icon = NSImage(named: "VoxPalm") {
                Image(nsImage: icon).resizable().frame(width: 84, height: 84)
            }
            Text("按住说话，松手出字").font(.title2.bold())
            Text("把遥控器和无线麦，变成 Mac 的语音按钮。\n设置大约要两分钟。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("打开 3 个权限").font(.title2.bold())
            VStack(spacing: 0) {
                ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider() }
                    let granted = model.permissions[permission] == true
                    HStack(spacing: 12) {
                        ZStack {
                            Circle().fill((granted ? Color.green : Color.orange).opacity(0.16)).frame(width: 28, height: 28)
                            Image(systemName: granted ? "checkmark" : "exclamationmark.triangle.fill")
                                .foregroundStyle(granted ? Color.green : Color.orange).font(.caption.weight(.bold))
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(permission.title)
                            Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if !granted { Button("去打开") { permission.request() } }
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            Text("在系统设置里打开「掌声」的开关，回到这里会自动打勾。").font(.callout).foregroundStyle(.secondary)
        }
    }

    private var devices: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("用什么按，用什么收音").font(.title2.bold())
            VStack(spacing: 0) {
                Picker("控制设备", selection: Binding(get: { model.config.controlDeviceIDs.first ?? "" },
                                                 set: { model.selectControlDevice($0.isEmpty ? nil : $0) })) {
                    Text("还没选").tag("")
                    ForEach(model.devices) { Text($0.name).tag($0.id) }
                }
                .padding(12)
                Divider()
                Picker("收音设备", selection: model.binding(\.voice.micUID)) {
                    Text("跟随系统默认输入").tag(String?.none)
                    ForEach(model.micDevices) { Text($0.name).tag(Optional($0.uid)) }
                }
                .padding(12)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
            Text("两个可以不是同一台：用遥控器按键，用好一点的麦克风收音。列表里没有的话，先在系统设置里连上蓝牙。")
                .font(.callout).foregroundStyle(.secondary)
        }
        .onAppear { model.refreshDevices() }
    }

    private var talkKey: some View {
        let reportsRelease = model.activeDevice?.reportsRelease ?? true
        return VStack(alignment: .leading, spacing: 16) {
            Text("设一个说话键").font(.title2.bold())
            HStack {
                Spacer()
                ZStack {
                    RoundedRectangle(cornerRadius: 18).fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 18).stroke(Brand.coralTop, lineWidth: learnedName == nil ? 1 : 2.5)
                    Text(learnedName ?? "按一下\n设备上的键").font(.headline).multilineTextAlignment(.center)
                        .foregroundStyle(learnedName == nil ? .secondary : .primary)
                }
                .frame(width: 120, height: 120)
                Spacer()
            }
            if let name = learnedName {
                Text(reportsRelease
                     ? "学到了「\(name)」。**长按它就是按住说话**，松手出字。现在按住它，说一句试试。"
                     : "学到了「\(name)」。**单击它开始说话，再单击一下出字**。现在试一句。")
                    .foregroundStyle(.secondary)
            } else {
                Text("按一下你想用来说话的那个键，比如遥控器的确认键、无线麦的录制键。").foregroundStyle(.secondary)
            }
        }
        .onAppear(perform: learn)
    }

    private func learn() {
        guard learnedName == nil, model.activeDevice != nil else { return }
        let reportsRelease = model.activeDevice?.reportsRelease ?? true
        model.startLearning(spot: "+", purpose: "onboarding") { event in
            learnedName = event.label
            model.setBinding(KeyBinding(button: event.button, buttonLabel: event.label,
                                        gesture: reportsRelease ? .long : .single,
                                        action: reportsRelease ? .pushToTalk : .toggleDictation))
        }
    }
}
