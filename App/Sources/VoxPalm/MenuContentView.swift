import AppKit
import SwiftUI
import VoxPalmVoice

/// 点菜单栏图标弹出的小面板。
struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("掌声 VoxPalm").font(.headline)
                Spacer()
                Text(stateText)
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(stateColor.opacity(0.15), in: Capsule())
                    .foregroundStyle(stateColor)
            }

            if !model.missingPermissions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("还缺权限：" + model.missingPermissions.map(\.title).joined(separator: "、"), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button("去打开权限…") { openSettings() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }

            Divider()

            row("控制设备", model.activeDevice?.name ?? "还没选", detail: model.activeDeviceStatus)
            row("收音设备", model.selectedMic?.name ?? "系统默认输入",
                detail: model.selectedMic.flatMap { mic in mic.isLowRateBluetoothInput ? "蓝牙通话音质 \(Int(mic.nominalSampleRate / 1000)) kHz" : nil })
            row("出字方式", model.config.voice.mode.title, detail: nil)

            if model.lastButton != nil || model.lastGesture != nil {
                Divider()
                if let button = model.lastButton { row("最近按键", button, detail: nil) }
                if let gesture = model.lastGesture { row("最近动作", gesture, detail: nil) }
            }
            if let transcript = model.lastTranscript {
                row("最近出字", transcript, detail: nil)
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }

            Divider()

            HStack {
                Button("设置…") { openSettings() }
                Button(model.voiceState == .idle ? "试一下说话" : "结束") {
                    if model.voiceState == .idle { model.tryVoice() } else { model.voice.voiceEnd() }
                }
                .help("不按键，直接开始说话 3 秒")
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var stateText: String {
        switch model.voiceState {
        case .idle: return "待命"
        case .armed: return "准备中"
        case .listening: return "正在听"
        case .transcribing: return "转写中"
        }
    }

    private var stateColor: Color {
        switch model.voiceState {
        case .idle: return .secondary
        case .armed, .listening: return .red
        case .transcribing: return .orange
        }
    }

    private func row(_ title: String, _ value: String, detail: String?) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(value).lineLimit(2)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
        }
        .font(.callout)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}
