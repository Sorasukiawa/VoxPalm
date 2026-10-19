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
        .frame(width: 600, height: 560)
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

// MARK: - 按键

private struct KeysTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if model.activeDevice == nil {
                    Text("先在「设备」里选一个控制设备。").foregroundStyle(.secondary)
                } else if model.isLearning {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("请按一下「\(model.activeDevice?.name ?? "")」上的键……")
                        Spacer()
                        Button("取消") { model.cancelLearning() }
                    }
                } else if let learned = model.learned {
                    BindingEditor(event: learned, reportsRelease: model.activeDevice?.reportsRelease ?? true)
                } else {
                    Button("学一个键") { model.startLearning() }
                    Text("点「学一个键」，再按一下设备上的键，然后选这个键的单击、双击或长按做什么。").font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("添加映射")
            }

            Section("已有映射（\(model.config.keyMap.name)）") {
                if model.config.keyMap.bindings.isEmpty {
                    Text("还没有映射。").foregroundStyle(.secondary)
                }
                ForEach(model.config.keyMap.bindings) { binding in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(binding.buttonLabel) · \(binding.gesture.title)")
                            Text(binding.action.title).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(role: .destructive) { model.removeBinding(binding.id) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            Section("手势判定") {
                LabeledContent("双击间隔") {
                    Slider(value: model.binding(\.timing.doubleTapWindow), in: 0.15...0.6, step: 0.05)
                    Text(String(format: "%.2f 秒", model.config.timing.doubleTapWindow)).monospacedDigit().frame(width: 60)
                }
                LabeledContent("长按多久算长按") {
                    Slider(value: model.binding(\.timing.longPressThreshold), in: 0.25...1.5, step: 0.05)
                    Text(String(format: "%.2f 秒", model.config.timing.longPressThreshold)).monospacedDigit().frame(width: 60)
                }
            }

            Section("导入导出") {
                HStack {
                    Button("导出设置…") { exportConfig() }
                    Button("导入设置…") { importConfig() }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "掌声设置.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.exportConfig(to: url)
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? model.importConfig(from: url)
    }
}

/// 学到一个键后，选手势和动作。
private struct BindingEditor: View {
    @Environment(AppModel.self) private var model
    let event: ButtonEvent
    let reportsRelease: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case pushToTalk, toggleDictation, shortcut, text, mediaKey, openApp
        var id: String { rawValue }
        var title: String {
            switch self {
            case .pushToTalk: return "按住说话"
            case .toggleDictation: return "按一下开始 / 结束说话"
            case .shortcut: return "快捷键"
            case .text: return "输入一段文字"
            case .mediaKey: return "媒体键"
            case .openApp: return "打开 App"
            }
        }
    }

    @State private var gesture: GestureKind = .single
    @State private var kind: Kind = .shortcut
    @State private var combo: KeyCombo?
    @State private var text = ""
    @State private var media: MediaKey = .playPause
    @State private var appPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("按键", value: event.label)
            Picker("手势", selection: $gesture) {
                ForEach(GestureKind.allCases.filter { reportsRelease || $0 != .long }, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("动作", selection: $kind) {
                ForEach(Kind.allCases.filter { $0 != .pushToTalk || gesture == .long }) { Text($0.title).tag($0) }
            }
            switch kind {
            case .pushToTalk:
                Text("按住开始说话，松手出字。按下的瞬间就开始录音，不会吞掉第一个字。").font(.caption).foregroundStyle(.secondary)
            case .toggleDictation:
                Text("按一下开始说话，再按一下结束出字。").font(.caption).foregroundStyle(.secondary)
            case .shortcut:
                ShortcutRecorder(combo: $combo)
            case .text:
                TextField("要输入的文字", text: $text)
            case .mediaKey:
                Picker("媒体键", selection: $media) {
                    ForEach(MediaKey.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            case .openApp:
                HStack {
                    Text(appPath.map { ($0 as NSString).lastPathComponent } ?? "还没选")
                    Button("选择 App…") { chooseApp() }
                }
            }
            HStack {
                Button("取消") { model.learned = nil }
                Spacer()
                Button("添加") {
                    guard let action else { return }
                    model.addBinding(button: event.button, label: event.label, gesture: gesture, action: action)
                    model.learned = nil
                }
                .keyboardShortcut(.defaultAction)
                .disabled(action == nil)
            }
        }
        .onChange(of: gesture) { _, new in
            if new != .long, kind == .pushToTalk { kind = .toggleDictation }
        }
    }

    private var action: Action? {
        switch kind {
        case .pushToTalk: return .pushToTalk
        case .toggleDictation: return .toggleDictation
        case .shortcut: return combo.map(Action.shortcut)
        case .text: return text.isEmpty ? nil : .text(text)
        case .mediaKey: return .mediaKey(media)
        case .openApp: return appPath.map { .openApp(path: $0) }
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        appPath = url.path
    }
}

/// 点一下然后按快捷键，记下键码和修饰键。
private struct ShortcutRecorder: View {
    @Binding var combo: KeyCombo?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(combo?.display ?? "还没设置").monospaced()
            Button(recording ? "请按快捷键…" : "录制快捷键") { recording ? stop() : start() }
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            combo = KeyCombo(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue),
                             display: KeyNames.display(keyCode: event.keyCode, flags: flags, characters: event.charactersIgnoringModifiers))
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum KeyNames {
    static func display(keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) -> String {
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        return text + (special[keyCode] ?? characters?.uppercased() ?? "#\(keyCode)")
    }

    static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]
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
