import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers
import VoxPalmDevices
import VoxPalmEngine
import VoxPalmVoice

/// 设置窗口左边栏的六页。
enum SettingsPane: String, CaseIterable, Identifiable {
    case devices, keys, voice, permissions, pro, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .devices: return "设备"
        case .keys: return "按键"
        case .voice: return "语音"
        case .permissions: return "权限"
        case .pro: return "Pro"
        case .about: return "关于"
        }
    }

    var symbol: String {
        switch self {
        case .devices: return "av.remote"
        case .keys: return "keyboard"
        case .voice: return "waveform"
        case .permissions: return "checkmark.shield"
        case .pro: return "star"
        case .about: return "info.circle"
        }
    }
}

@MainActor
@Observable
final class SettingsNavigation {
    var pane: SettingsPane = .keys
}

/// 设置窗口：系统设置那样的左边栏，右边是分组表单。
struct SettingsView: View {
    @Environment(SettingsNavigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(get: { navigation.pane }, set: { if let pane = $0 { navigation.pane = pane } })) { pane in
                Label(pane.title, systemImage: pane.symbol).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            switch navigation.pane {
            case .devices: DevicesPane()
            case .keys: KeysPane()
            case .voice: VoicePane()
            case .permissions: PermissionsPane()
            case .pro: ProPane()
            case .about: AboutPane()
            }
        }
        .tint(Brand.coralBottom)
        .frame(minWidth: 860, minHeight: 640)
    }
}

/// 每页上面一条：标题，右边放这一页的主按钮。
struct PaneScaffold<Tools: View, Content: View>: View {
    let title: String
    @ViewBuilder var tools: () -> Tools
    @ViewBuilder var content: () -> Content

    init(title: String, @ViewBuilder tools: @escaping () -> Tools = { EmptyView() }, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.tools = tools
        self.content = content
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                tools()
            }
            .padding(.horizontal, 20)
            .frame(height: 44)
            Divider()
            content()
        }
    }
}

/// 分组下面的说明：左对齐的灰色小字（系统默认会排成右对齐）。
struct FootNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension AppModel {
    func binding<T>(_ keyPath: WritableKeyPath<AppConfig, T>) -> Binding<T> {
        Binding(get: { self.config[keyPath: keyPath] }, set: { value in self.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: - 设备

struct DevicesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "设备") {
            Button("刷新") { model.refreshDevices() }
        } content: {
            Form {
                Section {
                    RadioRow(selected: model.config.controlDeviceIDs.isEmpty, icon: "nosign", title: "不用", detail: nil, status: nil) {
                        model.selectControlDevice(nil)
                    }
                    ForEach(model.devices) { device in
                        let selected = model.config.controlDeviceIDs.contains(device.id)
                        RadioRow(selected: selected, icon: Self.icon(for: device), title: device.name, detail: device.detail,
                                 status: selected ? (model.isPaused ? ("已暂停", .secondary) : ("正在监听", .green)) : nil) {
                            model.selectControlDevice(device.id)
                        }
                    }
                } header: {
                    HStack {
                        Text("控制设备")
                        Spacer()
                        Text("免费版同时用 1 台").font(.caption).padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                } footer: {
                    FootNote("列表里没有你的设备时，先在系统设置里配好对，再点右上角的刷新。想让遥控器和脚踏板一起用，是 Pro 功能。")
                }

                Section {
                    RadioRow(selected: model.config.voice.micUID == nil, icon: "gearshape", title: "跟随系统默认输入",
                             detail: AudioDevices.inputs().first(where: \.isDefaultInput)?.name, status: nil) {
                        model.update { $0.voice.micUID = nil }
                    }
                    ForEach(model.micDevices) { mic in
                        let selected = model.config.voice.micUID == mic.uid
                        RadioRow(selected: selected, icon: Self.icon(for: mic), title: mic.name, detail: Self.detail(for: mic),
                                 status: mic.isLowRateBluetoothInput ? ("通话音质", .orange) : nil) {
                            model.update { $0.voice.micUID = mic.uid }
                        }
                    }
                } header: {
                    Text("收音设备")
                } footer: {
                    FootNote("收音设备可以和控制设备不是同一台：用遥控器按键，用好一点的麦克风收音。掌声直接从这里录音，不改系统的默认输入。")
                }
            }
            .formStyle(.grouped)
        }
        .onAppear { model.refreshDevices() }
    }

    static func icon(for device: ControlDevice) -> String {
        switch device.sourceID {
        case "system-keys": return device.id == SystemKeysControlSource.mediaDeviceID ? "playpause" : "keyboard"
        case "now-playing": return "headphones"
        case "dji": return "mic"
        default: return device.detail.contains("键盘") && !device.detail.contains("媒体键") ? "keyboard" : "av.remote"
        }
    }

    static func icon(for mic: AudioDeviceInfo) -> String {
        if mic.isBluetooth { return "headphones" }
        switch mic.transport {
        case "USB": return "cable.connector"
        case "Built-in": return "laptopcomputer"
        default: return mic.transport.hasPrefix("Continuity") ? "iphone" : "mic"
        }
    }

    static func transportName(_ mic: AudioDeviceInfo) -> String {
        if mic.isBluetooth { return "蓝牙" }
        switch mic.transport {
        case "Built-in": return "内置"
        case "Virtual": return "虚拟声卡"
        default: return mic.transport.hasPrefix("Continuity") ? "iPhone 连续互通" : mic.transport
        }
    }

    static func detail(for mic: AudioDeviceInfo) -> String {
        var text = "\(transportName(mic)) · \(Int(mic.nominalSampleRate / 1000)) kHz"
        if mic.isLowRateBluetoothInput { text += " · 蓝牙通话音质，转写会差一些" }
        if mic.isDefaultInput { text += " · 系统默认" }
        return text
    }
}

/// 单选的一行：圆圈 + 图标 + 名字和说明 + 右边的状态。
struct RadioRow: View {
    let selected: Bool
    let icon: String
    let title: String
    let detail: String?
    let status: (String, Color)?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().stroke(selected ? Brand.coralBottom : Color.secondary.opacity(0.5), lineWidth: 1.5).frame(width: 16, height: 16)
                    if selected { Circle().fill(Brand.coral).frame(width: 9, height: 9) }
                }
                Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if let status { StatusDot(color: status.1, text: status.0) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 语音

struct VoicePane: View {
    @Environment(AppModel.self) private var model
    @State private var modelStatus: String?

    private let locales: [(String, String)] = [
        ("zh-CN", "普通话（简体）"), ("zh-TW", "国语（繁体）"), ("yue-CN", "粤语"), ("en-US", "英语"), ("ja-JP", "日语"),
    ]

    var body: some View {
        PaneScaffold(title: "语音") {
        Form {
            Section {
                Picker("出字方式", selection: model.binding(\.voice.mode)) {
                    ForEach(VoiceSession.Mode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                FootNote(model.config.voice.mode == .builtIn
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
                    FootNote("macOS 26 以下没有系统转写，用 whisper.cpp：先装好 whisper-cli（比如 brew install whisper-cpp），再选一个 ggml 模型文件。")
                }
                Section {
                    PrebufferTimeline(warm: model.config.voice.keepMicWarm, warmSeconds: model.config.voice.warmSeconds,
                                      threshold: model.config.timing.longPressThreshold)
                        .frame(height: 74)
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
                    FootNote("默认按下键的瞬间开麦。蓝牙麦开麦要半秒以上时，打开预热：麦克风一直开着，按键前的声音也会算进去，代价是麦克风指示灯常亮。")
                }
            } else {
                Section {
                    InputMethodFlow(mic: model.selectedMic?.name ?? "你选的麦克风", key: model.config.voice.inputMethodKey.key.title)
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
                    FootNote("要和输入法里设置的语音键一致。系统听写默认是「连按两下 Fn」。")
                }
            }
        }
        .formStyle(.grouped)
        }
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

/// 防吞字的时间线：按下前保留的一段（预热时）、按下、满长按时间才算数。
struct PrebufferTimeline: View {
    let warm: Bool
    let warmSeconds: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geometry in
            let span = 3.0 + 2.0
            let x = { (t: Double) in geometry.size.width * (t + 3.0) / span }
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.07)).frame(height: 14).offset(y: 22)
                let start = warm ? -warmSeconds : 0
                Capsule().fill(Brand.coral).frame(width: max(6, x(2) - x(start)), height: 14).offset(x: x(start), y: 22)
                if warm {
                    Text("按键前保留 \(String(format: "%.1f", warmSeconds)) 秒").font(.caption2).foregroundStyle(Brand.coralText)
                        .offset(x: x(start), y: 2)
                }
                marker(x(0), "按下", color: .primary)
                marker(x(threshold), String(format: "满 %.2f 秒才算数", threshold), color: .secondary)
                Text(warm ? "按键前的声音也会算进去" : "按下的瞬间开始录，不会吞掉第一个字")
                    .font(.caption).foregroundStyle(.secondary).offset(y: 50)
            }
        }
    }

    private func marker(_ x: CGFloat, _ text: String, color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.7)).frame(width: 1.5, height: 26).offset(x: x, y: 16)
            Text(text).font(.caption2).foregroundStyle(color).fixedSize().offset(x: x + 4, y: 38)
        }
    }
}

/// 外部输入法模式下掌声做了什么，一排小块。
struct InputMethodFlow: View {
    let mic: String
    let key: String

    var body: some View {
        let steps = ["按住遥控器", "掌声切到 \(mic)", "替你按住 \(key)", "输入法出字", "切回原来的麦克风"]
        ViewThatFits {
            HStack(spacing: 6) { flow(steps) }
            VStack(alignment: .leading, spacing: 4) { flow(steps) }
        }
        .font(.caption)
    }

    @ViewBuilder
    private func flow(_ steps: [String]) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            if index > 0 { Image(systemName: "arrow.right").foregroundStyle(.tertiary) }
            Text(step).padding(.horizontal, 7).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
        }
    }
}

// MARK: - 权限

struct PermissionsPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "权限") {
            Form {
                Section {
                    ForEach(Permission.allCases) { permission in
                        let granted = model.permissions[permission] == true
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill((granted ? Color.green : Color.orange).opacity(0.16)).frame(width: 30, height: 30)
                                Image(systemName: granted ? "checkmark" : "exclamationmark.triangle.fill")
                                    .foregroundStyle(granted ? Color.green : Color.orange)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(permission.title)
                                Text(permission.purpose).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if granted {
                                Text("已打开").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Button("去打开") { permission.request() }
                            }
                        }
                    }
                } footer: {
                    FootNote("点「去打开」会弹出系统设置，在列表里打开「掌声」的开关。回到这里会自动打勾，输入监控打开后掌声会自动重新开始监听。macOS 27 里「辅助功能」可能叫「设备控制与数据访问」。")
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - Pro

struct ProPane: View {
    @Environment(AppModel.self) private var model

    private let features: [(String, String)] = [
        ("多台控制设备同时在线", "遥控器、脚踏板、无线麦一起用"),
        ("多套键位方案，按 App 自动切换", "在剪辑软件里和在编程工具里，同一个键做不同的事"),
        ("录音剪辑软件动作包", "Logic Pro、Final Cut Pro、Premiere Pro、DaVinci Resolve 等"),
        ("组合动作", "一个键依次执行多步"),
        ("转写增强", "热词和自定义词表、口语润色"),
        ("手机上的自定义面板", "掌声手机版按 Mac 当前的 App 换按键面板"),
    ]

    var body: some View {
        PaneScaffold(title: "Pro") {
            Form {
                Section {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("免费版已经能完整用「按键 → 说话 → 出字」，全部设备都能用。Pro 是一次买断，给多设备、多场景和录音剪辑。")
                            Text("1.0 正式版发布时开卖。现在是\(model.engine.gate.editionName)。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("了解 Pro") {}.disabled(true)
                    }
                }
                Section("Pro 里有什么") {
                    ForEach(features, id: \.0) { feature in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(feature.0)
                            Text(feature.1).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
    }
}

// MARK: - 关于

struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "关于") {
            VStack(spacing: 12) {
                if let icon = NSImage(named: "VoxPalm") {
                    Image(nsImage: icon).resizable().frame(width: 96, height: 96)
                }
                Text("掌声 VoxPalm").font(.title2.bold())
                Text("按住说话，松手出字").foregroundStyle(.secondary)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · \(PrivateModules.buildFlavor) · \(model.engine.gate.editionName)")
                    .font(.caption)
                Text("代码按 GPL-3.0-only 开源；名字和图标是专有品牌素材。").font(.caption).foregroundStyle(.secondary)
                Button("重新走一遍第一次的引导") { model.openOnboarding() }
                    .padding(.top, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
