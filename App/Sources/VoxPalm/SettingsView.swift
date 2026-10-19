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
        case .devices: return "av.remote.fill"
        case .keys: return "keyboard.fill"
        case .voice: return "waveform"
        case .permissions: return "hand.raised.fill"
        case .pro: return "star.fill"
        case .about: return "info"
        }
    }

    var tileColor: Color {
        switch self {
        case .devices: return .tileBlue
        case .keys: return .tileIndigo
        case .voice: return Brand.coralBottom
        case .permissions: return .tileGreen
        case .pro: return .tileOrange
        case .about: return .tileGray
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
                Label {
                    Text(pane.title)
                } icon: {
                    IconTile(symbol: pane.symbol, color: pane.tileColor, size: 22)
                }
                .padding(.vertical, 2)
                .tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            Group {
                switch navigation.pane {
                case .devices: DevicesPane()
                case .keys: KeysPane()
                case .voice: VoicePane()
                case .permissions: PermissionsPane()
                case .pro: ProPane()
                case .about: AboutPane()
                }
            }
            .id(navigation.pane)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: Motion.reduceMotion ? 0 : 10)),
                                    removal: .opacity.animation(.easeIn(duration: 0.1))))
            .animation(Motion.pick(Motion.smooth), value: navigation.pane)
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
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 22, weight: .bold))
                Spacer()
                tools()
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 2)
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
    @State private var showsMics = false

    var body: some View {
        PaneScaffold(title: "设备") {
            Button { model.refreshDevices() } label: { Label("刷新", systemImage: "arrow.clockwise") }
                .secondaryButton()
        } content: {
            // 放进滚动区：分栏视图的右栏直接放固定高度的内容时，屏幕外排版会整页错位
            ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Picker("设备", selection: $showsMics.animation(Motion.pick(Motion.smooth))) {
                        Text("控制设备").tag(false)
                        Text("收音设备").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 200)
                    Text(showsMics ? "收音可以和按键的不是同一台" : "免费版同时用 1 台 · Pro 可以几台一起用")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Group {
                    if showsMics {
                        MicPicker(stageWidth: 300).transition(.opacity.combined(with: .offset(y: 8)))
                    } else {
                        ControlDevicePicker(identifies: false, stageWidth: 300).transition(.opacity.combined(with: .offset(y: 8)))
                    }
                }
                .frame(height: 430)
                FootNote(showsMics
                         ? "掌声直接从这里录音，不改系统的默认输入。蓝牙耳机的麦是通话音质（16 kHz），转写会差一些。"
                         : "转到哪台就用哪台。没连上的型号是灰的：先在系统设置 › 蓝牙 里配对，连上后会自己出现在列表里。")
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .onAppear(perform: applyFocus)
        .onChange(of: model.settingsFocus) { _, _ in applyFocus() }
    }

    private func applyFocus() {
        guard model.settingsFocus?.showsMics == true else { return }
        model.consumeSettingsFocus()
        withAnimation(Motion.pick(Motion.smooth)) { showsMics = true }
    }

    static func transportName(_ mic: AudioDeviceInfo) -> String {
        if mic.isBluetooth { return "蓝牙" }
        switch mic.transport {
        case "Built-in": return "内置"
        case "Virtual": return "虚拟声卡"
        default: return mic.transport.hasPrefix("Continuity") ? "iPhone 连续互通" : mic.transport
        }
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
                VoiceModeCards()
            } header: {
                Text("出字方式")
            } footer: {
                if model.config.voice.mode == .inputMethod {
                    FootNote("说话期间临时把系统默认输入切到你选的收音设备，结束后切回。")
                }
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
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    PermissionStack(expandsCurrent: true)
                    FootNote("点「开启」会打开系统设置，旁边浮出掌声的图标，把它拖进列表就行（麦克风是系统直接弹框问你）。打开后这里自动打勾，掌声会自动重新开始监听。")
                        .padding(.top, 6)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }
}

// MARK: - Pro

struct ProPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "Pro") {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 16) {
                        LogoMark(size: 56, interactive: false)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("掌声 Pro").font(.headline)
                            Text("免费版已经能完整用「按键 → 说话 → 出字」，全部设备都能用。Pro 是一次买断，给多设备、多场景和录音剪辑。")
                                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: 8) {
                                Button("了解 Pro") {}.prominentButton().controlSize(.small).disabled(true)
                                Text("1.0 正式版发布时开卖 · 现在是\(model.engine.gate.editionName)").font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.top, 4)
                        }
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(colors: [Brand.coralTop.opacity(0.16), Color.tilePurple.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                    .staggerIn(0)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                        ForEach(Array(ProFeatureCard.Kind.allCases.enumerated()), id: \.offset) { index, kind in
                            ProFeatureCard(kind: kind).staggerIn(index + 1)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - 关于

struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "关于") {
            VStack(spacing: 10) {
                LogoMark(size: 112)
                    .padding(.bottom, 8)
                Text("掌声 VoxPalm").font(.system(size: 26, weight: .bold))
                Text("按住说话，松手出字").foregroundStyle(.secondary)
                Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版") · \(PrivateModules.buildFlavor) · \(model.engine.gate.editionName)")
                    .font(.caption)
                Text("代码按 GPL-3.0-only 开源；名字和图标是专有品牌素材。").font(.caption).foregroundStyle(.secondary)
                Button("重新打开引导") { model.openOnboarding() }
                    .secondaryButton()
                    .controlSize(.large)
                    .padding(.top, 10)
                Text("按住上面的 Logo 试试").font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
