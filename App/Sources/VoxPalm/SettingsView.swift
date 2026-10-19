import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VoxPalmDevices
import VoxPalmEngine
import VoxPalmVoice

struct SettingsView: View {
    var body: some View {
        TabView {
            DevicesTab().tabItem { Label("设备", systemImage: "dot.radiowaves.left.and.right") }
            KeysTab().tabItem { Label("按键", systemImage: "keyboard") }
            VoiceTab().tabItem { Label("语音", systemImage: "waveform") }
            PermissionsTab().tabItem { Label("权限", systemImage: "lock.shield") }
            AboutTab().tabItem { Label("关于", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 760)
    }
}

extension AppModel {
    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - 设备

private struct DevicesTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("控制设备", selection: Binding(
                    get: { model.config.controlDeviceIDs.first ?? "" },
                    set: { model.selectControlDevice($0.isEmpty ? nil : $0) }
                )) {
                    Text("不用").tag("")
                    ForEach(model.devices) { device in
                        Text(device.name).tag(device.id)
                    }
                }
                if let device = model.activeDevice {
                    Text(device.detail).font(.caption).foregroundStyle(.secondary)
                    if !device.reportsRelease {
                        Text("这台设备读不到「松开」，只能用单击和双击，做不了长按和按住说话。").font(.caption).foregroundStyle(.orange)
                    }
                }
                if let status = model.activeDeviceStatus {
                    LabeledContent("状态", value: status)
                }
                Button("刷新设备列表") { model.refreshDevices() }
            } header: {
                Text("控制设备")
            } footer: {
                Text("用来按键的设备。免费版同时用 1 台；多台同时在线是 Pro 功能。列表里没有你的设备时，先在系统设置里配对好，再点刷新。")
            }

            Section {
                Picker("收音设备", selection: model.binding(\.voice.micUID)) {
                    Text("跟随系统默认输入").tag(String?.none)
                    ForEach(model.micDevices) { mic in
                        Text(micLabel(mic)).tag(Optional(mic.uid))
                    }
                }
                if let mic = model.selectedMic, mic.isLowRateBluetoothInput {
                    Text("这是蓝牙通话音质（\(Int(mic.nominalSampleRate / 1000)) kHz），能用，但转写会比有线麦或 USB 接收器差一些。")
                        .font(.caption).foregroundStyle(.orange)
                }
            } header: {
                Text("收音设备")
            } footer: {
                Text("说话用的麦克风，可以和控制设备不是同一台：比如用遥控器按键、用专业麦克风收音。")
            }
        }
        .formStyle(.grouped)
        .onAppear { model.refreshDevices() }
    }

    private func micLabel(_ mic: AudioDeviceInfo) -> String {
        var text = mic.name
        if mic.isBluetooth { text += "（蓝牙 \(Int(mic.nominalSampleRate / 1000)) kHz）" }
        if mic.isDefaultInput { text += " · 系统默认" }
        return text
    }
}

// MARK: - 语音

private struct VoiceTab: View {
    @Environment(AppModel.self) private var model
    @State private var modelStatus: String?

    private let locales: [(String, String)] = [
        ("zh-CN", "普通话（简体）"), ("zh-TW", "国语（繁体）"), ("yue-CN", "粤语"), ("en-US", "英语"), ("ja-JP", "日语"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("出字方式", selection: model.binding(\.voice.mode)) {
                    ForEach(VoiceSession.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(model.config.voice.mode == .builtIn
                     ? "掌声自己录音、在本机转成文字，贴到光标处。"
                     : "掌声按住你的输入法（豆包、微信输入法、Typeless、系统听写等）的语音键，让输入法出字；说话期间临时把系统默认输入切到你选的收音设备，结束后切回。")
            }

            if model.config.voice.mode == .builtIn {
                Section("内置转写") {
                    Picker("转写引擎", selection: model.binding(\.voice.transcriber)) {
                        ForEach(TranscriberChoice.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("语言", selection: model.binding(\.voice.localeID)) {
                        ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    if TranscriberFactory.appleSpeechAvailable {
                        HStack {
                            Button("检查系统转写模型") { checkModel() }
                            if let modelStatus { Text(modelStatus).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    Picker("文字放入方式", selection: model.binding(\.voice.textMethod)) {
                        ForEach(TextInserter.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section {
                    LabeledContent("程序", value: model.config.voice.whisper.resolvedExecutable ?? "没找到 whisper-cli")
                    HStack {
                        Text(model.config.voice.whisper.modelPath.map { ($0 as NSString).lastPathComponent } ?? "还没选模型")
                        Spacer()
                        Button("选择模型文件…") { chooseWhisperModel() }
                    }
                } header: {
                    Text("whisper.cpp（老系统兜底）")
                } footer: {
                    Text("macOS 26 以下没有系统转写，用 whisper.cpp：先装好 whisper-cli（比如 brew install whisper-cpp），再选一个 ggml 模型文件。")
                }
                Section {
                    Toggle("一直开着麦克风（预热）", isOn: model.binding(\.voice.keepMicWarm))
                    if model.config.voice.keepMicWarm {
                        LabeledContent("保留按键前") {
                            Slider(value: model.binding(\.voice.warmSeconds), in: 0.5...3, step: 0.5)
                            Text(String(format: "%.1f 秒", model.config.voice.warmSeconds)).monospacedDigit().frame(width: 50)
                        }
                    }
                } header: {
                    Text("防吞字")
                } footer: {
                    Text("默认按下键的瞬间开麦。蓝牙麦开麦要半秒以上时，打开预热：麦克风一直开着，按键前的声音也会算进去，代价是麦克风指示灯常亮。")
                }
            } else {
                Section {
                    Picker("输入法的语音键", selection: model.binding(\.voice.inputMethodKey.key)) {
                        ForEach(InputMethodKey.Key.allCases.filter { $0 != .custom }, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("怎么按", selection: model.binding(\.voice.inputMethodKey.style)) {
                        ForEach(InputMethodKey.Style.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    LabeledContent("松手后多久切回麦克风") {
                        Slider(value: model.binding(\.voice.restoreInputDelay), in: 0...5, step: 0.5)
                        Text(String(format: "%.1f 秒", model.config.voice.restoreInputDelay)).monospacedDigit().frame(width: 50)
                    }
                } header: {
                    Text("外部输入法")
                } footer: {
                    Text("要和输入法里设置的语音键一致。系统听写默认是「连按两下 Fn」。")
                }
            }
        }
        .formStyle(.grouped)
    }

    private func checkModel() {
        guard #available(macOS 26, *) else { return }
        modelStatus = "检查中……"
        let locale = Locale(identifier: model.config.voice.localeID)
        Task {
            do {
                modelStatus = try await SpeechAnalyzerTranscriber.prepare(locale: locale)
            } catch {
                modelStatus = "失败：\(error.localizedDescription)"
            }
        }
    }

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data, UTType(filenameExtension: "gguf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.voice.whisper.modelPath = url.path }
    }
}

// MARK: - 权限

private struct PermissionsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(Permission.allCases) { permission in
                    HStack {
                        Image(systemName: model.permissions[permission] == true ? "checkmark.circle.fill" : "xmark.circle")
                            .foregroundStyle(model.permissions[permission] == true ? .green : .orange)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(permission.title)
                            Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if model.permissions[permission] != true {
                            Button("去打开") { permission.request() }
                        }
                    }
                }
            } footer: {
                Text("点「去打开」会弹出系统设置，在列表里打开「掌声」的开关。输入监控打开后，掌声会自动重新开始监听。")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - 关于

private struct AboutTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 12) {
            if let icon = NSImage(named: "VoxPalm") {
                Image(nsImage: icon).resizable().frame(width: 96, height: 96)
            }
            Text("掌声 VoxPalm").font(.title2.bold())
            Text("按住说话，松手出字").foregroundStyle(.secondary)
            Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · \(PrivateModules.buildFlavor) · \(model.engine.gate.editionName)")
                .font(.caption)
            Text("代码按 GPL-3.0-only 开源；名字和图标是专有品牌素材。").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
