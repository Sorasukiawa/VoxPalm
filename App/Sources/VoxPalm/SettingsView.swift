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

/// 设置窗口（设计稿第 06 节）：左边是浮起来的一块边栏，选中的底色用弹簧滑过去；右边每页是大标题加一句说明、下面一张张卡片，
/// 底下透一点珊瑚色的光，和引导同一套样子。换页时旧页淡出、新页往上浮，页里的卡片依次浮上来。
struct SettingsView: View {
    @Environment(SettingsNavigation.self) private var navigation
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar()
                .frame(width: 214)
                .padding(.leading, 10)
                .padding(.vertical, 10)
                .ignoresSafeArea(.container, edges: .top)
            VStack(spacing: 0) {
                if let problem = model.configProblem {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("设置还没有保存。\(problem)").font(.caption).textSelection(.enabled)
                        Spacer(minLength: 0)
                        Button("查看与备份") { navigation.pane = .about }
                            .secondaryButton().controlSize(.small)
                    }
                    .padding(14)
                }
                ZStack(alignment: .topLeading) {
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
                    .transition(.paneSwap)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .animation(Motion.pick(Motion.smooth), value: navigation.pane)
        }
        .background(BrandBackdrop())
        .tint(Brand.coralBottom)
        .frame(minWidth: 860, minHeight: 640)
    }
}

/// 左边栏：六页，选中的底色滑过去；「权限」缺几个就挂几的角标；最下面是监听状态和开关。
private struct SettingsSidebar: View {
    @Environment(AppModel.self) private var model
    @Environment(SettingsNavigation.self) private var navigation
    @Namespace private var selection
    @State private var hovered: SettingsPane?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { index, pane in
                item(pane, index: index)
            }
            Spacer(minLength: 12)
            status
        }
        .padding(.horizontal, 9)
        .padding(.top, 50)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .floatingGlass(cornerRadius: 20)
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(.upArrow) { step(-1) }
        .onKeyPress(.downArrow) { step(1) }
    }

    private func item(_ pane: SettingsPane, index: Int) -> some View {
        let on = navigation.pane == pane
        let missing = pane == .permissions ? model.missingPermissions.count : 0
        return Button { select(pane) } label: {
            HStack(spacing: 10) {
                IconTile(symbol: pane.symbol, color: pane.tileColor, size: 24)
                Text(pane.title).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                Spacer(minLength: 4)
                if missing > 0 {
                    Text("\(missing)").font(.caption2.weight(.bold)).foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Capsule().fill(Color.tileOrange))
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        .help("还差 \(missing) 个权限")
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 36)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Brand.coralTop.opacity(0.18))
                        .matchedGeometryEffect(id: "selection", in: selection)
                } else if hovered == pane {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle())
        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
        .onHover { inside in
            if inside { hovered = pane } else if hovered == pane { hovered = nil }
        }
        .animation(Motion.pick(Motion.bounce), value: missing)
    }

    /// 最下面一块：在不在监听、用的哪台，旁边一个开关（和面板里的「监听」是同一个）。
    private var status: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(model.isPaused ? Color.secondary.opacity(0.6) : (model.activeDeviceConnected ? Color.tileGreen : Color.tileOrange))
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isPaused ? "已暂停监听" : "正在监听").font(.caption.weight(.semibold))
                Text(model.activeShortName ?? "还没选控制设备").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Toggle("监听", isOn: Binding(get: { !model.isPaused }, set: { model.setPaused(!$0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .help("关掉后掌声不读按键，遥控器照常控制别的 App")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .animation(Motion.pick(Motion.bounce), value: model.isPaused)
    }

    private func select(_ pane: SettingsPane) {
        guard navigation.pane != pane else { return }
        withAnimation(Motion.pick(Motion.smooth)) { navigation.pane = pane }
    }

    private func step(_ delta: Int) -> KeyPress.Result {
        let all = SettingsPane.allCases
        guard let index = all.firstIndex(of: navigation.pane) else { return .ignored }
        let target = min(all.count - 1, max(0, index + delta))
        select(all[target])
        return .handled
    }
}

/// 每页的骨架：大标题加一句说明（和引导一样大），右边放这一页的按钮；下面的卡片放进滚动区，依次浮上来。
struct PaneScaffold<Tools: View, Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var tools: () -> Tools
    @ViewBuilder var content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder tools: @escaping () -> Tools = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.tools = tools
        self.content = content
    }

    var body: some View {
        // 放进滚动区：右栏直接放固定高度的内容时，屏幕外排版会整页错位
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(title).font(.system(size: 25, weight: .bold))
                        if let subtitle {
                            Text(subtitle).font(.system(size: 14)).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 8) { tools() }
                        .padding(.top, 3)
                }
                .padding(.bottom, 4)
                .staggerIn(0)
                content()
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
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
        PaneScaffold(title: "设备", subtitle: "转到哪台就用哪台。按键用的和收音用的，可以不是同一台。") {
            IconButton(symbol: "arrow.clockwise", help: "重新找一遍设备") { model.refreshDevices() }
        } content: {
            HStack(spacing: 10) {
                PillTabs(selection: $showsMics, options: [
                    .init(value: false, title: "控制设备", symbol: "av.remote"),
                    .init(value: true, title: "收音设备", symbol: "mic"),
                ])
                Spacer(minLength: 8)
                Text(showsMics ? "收音可以和按键的不是同一台" : "免费版同时用 1 台 · Pro 可以几台一起用")
                    .font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            .staggerIn(1)
            ZStack {
                if showsMics {
                    MicPicker(stageWidth: 300).transition(.swapIn)
                } else {
                    ControlDevicePicker(identifies: false, stageWidth: 300).transition(.swapIn)
                }
            }
            .frame(height: 440)
            .staggerIn(2)
            Hint(showsMics
                 ? "掌声直接从这里录音，不改系统的默认输入。蓝牙耳机的麦是通话音质（16 kHz），转写会差一些。"
                 : "没连上的型号是灰的：先在系统设置 › 蓝牙 里配对，连上后会自己出现在列表里。")
                .staggerIn(3)
        }
        .animation(Motion.pick(Motion.smooth), value: showsMics)
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
    @State private var checking = false
    /// 正在确认要不要删的 whisper.cpp 模型
    @State private var deletingModel: WhisperModel?
    @State private var deleteError: String?

    private let locales: [(String, String)] = [
        ("zh-CN", "普通话（简体）"), ("zh-TW", "国语（繁体）"), ("yue-CN", "粤语"), ("en-US", "英语"), ("ja-JP", "日语"),
    ]

    var body: some View {
        PaneScaffold(title: "语音", subtitle: "说的话怎么变成字：掌声自己转，或者交给你常用的输入法。") {
            VoiceModeCards().staggerIn(1)
            if model.config.voice.mode == .builtIn {
                builtInCard.staggerIn(2).transition(.swapIn)
                prebufferCard.staggerIn(3).transition(.swapIn)
                whisperCard.staggerIn(4).transition(.swapIn)
            } else {
                inputMethodCard.staggerIn(2).transition(.swapIn)
            }
        }
        .animation(Motion.pick(Motion.smooth), value: model.config.voice.mode)
        .animation(Motion.pick(Motion.smooth), value: model.config.voice.keepMicWarm)
    }

    private var builtInCard: some View {
        SettingsCard("内置转写", subtitle: "在这台 Mac 上转成字，声音不上传。", symbol: "cpu", color: .tileBlue) {
            VStack(spacing: 0) {
                SettingRow("转写引擎", detail: model.config.voice.transcriber == .automatic ? "新系统用系统转写，老系统用 whisper.cpp" : nil) {
                    Picker("转写引擎", selection: model.binding(\.voice.transcriber)) {
                        ForEach(TranscriberChoice.allCases, id: \.self) { Text($0.shortTitle).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow("语言") {
                    Picker("语言", selection: model.binding(\.voice.localeID)) {
                        ForEach(locales, id: \.0) { Text($0.1).tag($0.0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow("文字放进去的方式", detail: "粘贴最快；个别不让粘贴的输入框再换成逐字输入") {
                    Picker("文字放进去的方式", selection: model.binding(\.voice.textMethod)) {
                        ForEach(TextInserter.Method.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                if TranscriberFactory.appleSpeechAvailable {
                    RowDivider()
                    SettingRow("系统转写模型", detail: modelStatus ?? "第一次用某种语言时，系统要先下载它的模型") {
                        Button(checking ? "检查中…" : "检查") { checkModel() }
                            .secondaryButton()
                            .controlSize(.small)
                            .disabled(checking)
                    }
                }
            }
        }
    }

    private var prebufferCard: some View {
        SettingsCard("防吞字", subtitle: "按下的瞬间就开始录，第一个字不会丢。", symbol: "waveform.path", color: Brand.coralBottom) {
            VStack(spacing: 0) {
                PrebufferTimeline(warm: model.config.voice.keepMicWarm, warmSeconds: model.config.voice.warmSeconds,
                                  threshold: model.config.timing.longPressThreshold)
                    .frame(height: 74)
                    .padding(.bottom, 8)
                RowDivider()
                SettingRow("一直开着麦克风（预热）", detail: "蓝牙麦开麦要半秒以上时打开：按键前的声音也算进去，代价是麦克风指示灯常亮") {
                    Toggle("预热", isOn: model.binding(\.voice.keepMicWarm)).toggleStyle(.switch).labelsHidden()
                }
                if model.config.voice.keepMicWarm {
                    RowDivider()
                    SettingRow("保留按键前") {
                        SnapSlider(value: model.binding(\.voice.warmSeconds), in: 0.5...3, step: 0.5).frame(width: 180)
                        ValueChip(text: String(format: "%.1f 秒", model.config.voice.warmSeconds))
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    private var whisperCard: some View {
        let whisper = model.config.voice.whisper
        return SettingsCard("whisper.cpp", subtitle: "老系统兜底：macOS 26 以下没有系统转写时用它。whisper.cpp \(WhisperTranscriber.version) 已内置，下载一个模型就能用。",
                            symbol: "waveform", color: .tileGray) {
            VStack(spacing: 0) {
                SettingRow("模型", detail: whisper.usesCustomFile ? "用你自己的 whisper.cpp 模型文件（ggml 格式）" : whisper.model.summary) {
                    Picker("模型", selection: model.binding(\.voice.whisper.modelID)) {
                        ForEach(WhisperModel.catalog) { item in
                            Text("\(item.title) · \(item.sizeText)\(item == WhisperModel.recommended ? "（推荐）" : "")").tag(item.id)
                        }
                        Divider()
                        Text("自己的模型文件").tag(WhisperSettings.customID)
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                if whisper.usesCustomFile {
                    SettingRow("模型文件", detail: whisper.modelPath.map { ($0 as NSString).lastPathComponent } ?? "还没选，选一个 ggml 模型文件") {
                        Button("选择模型文件…") { chooseWhisperModel() }
                            .secondaryButton()
                            .controlSize(.small)
                    }
                } else {
                    whisperDownloadRow(whisper.model)
                }
            }
        }
        .onAppear { model.whisperModels.refresh() }
        .alert(deletingModel.map { "删除「\($0.title)」模型？" } ?? "", isPresented: Binding(get: { deletingModel != nil }, set: { if !$0 { deletingModel = nil } })) {
            Button("删除", role: .destructive) { deleteWhisperModel() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("删掉能腾出 \(deletingModel?.sizeText ?? "")，要用时可以重新下载。")
        }
    }

    /// 选中的清单模型这一行：没下载 → 下载按钮；下载中 → 进度和取消；失败 → 原因和重试；下好了 → 能用了。
    @ViewBuilder
    private func whisperDownloadRow(_ item: WhisperModel) -> some View {
        let models = model.whisperModels
        switch models.status[item.id] {
        case let .downloading(received, total, host):
            SettingRow("正在下载", detail: "\(Self.megabytes(received)) / \(Self.megabytes(total)) · 来自 \(host)") {
                ProgressView(value: Double(received), total: Double(max(total, 1)))
                    .frame(width: 140)
                Button("取消") { models.cancel(item) }
                    .secondaryButton()
                    .controlSize(.small)
            }
        case .verifying:
            SettingRow("正在核对文件", detail: "确认和官方发布的一模一样") {
                ProgressView().controlSize(.small)
            }
        case let .failed(message):
            SettingRow("下载没成功", detail: message) {
                Button("重试") { models.download(item) }
                    .prominentButton()
                    .controlSize(.small)
            }
        case nil:
            if models.isDownloaded(item) {
                SettingRow("已下载", detail: deleteError ?? "存在这台 Mac 上，转写不联网") {
                    StatusPill(text: "能用了", color: .tileGreen, symbol: "checkmark")
                    Button("删除…") { deletingModel = item }
                        .secondaryButton()
                        .controlSize(.small)
                }
            } else {
                SettingRow("还没下载", detail: "下载一次存在这台 Mac 上，之后转写不联网") {
                    Button("下载（\(item.sizeText)）") { models.download(item) }
                        .prominentButton()
                        .controlSize(.small)
                }
            }
        }
    }

    private static func megabytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal)
    }

    private var inputMethodCard: some View {
        SettingsCard("外部输入法", subtitle: "说话期间临时把系统默认输入切到你选的收音设备，结束后切回。", symbol: "globe", color: .tileIndigo) {
            VStack(alignment: .leading, spacing: 0) {
                InputMethodFlow(mic: model.pickerMics.first { $0.uid == model.config.voice.micUID }?.shortName ?? "你选的麦",
                                key: model.config.voice.inputMethodKey.key == .custom
                                    ? model.config.voice.inputMethodKey.custom?.display ?? "自定义快捷键"
                                    : model.config.voice.inputMethodKey.key.title,
                                style: model.config.voice.inputMethodKey.style)
                    .padding(.bottom, 12)
                RowDivider()
                SettingRow("输入法的语音键", detail: "按键和按法都要与输入法的设置一致；使用 Fn 按住说话前，先确认输入法里已启用它。系统听写可设为「连按两下 Fn」。") {
                    Picker("输入法的语音键", selection: model.binding(\.voice.inputMethodKey.key)) {
                        ForEach(InputMethodKey.Key.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    .onChange(of: model.config.voice.inputMethodKey.key) { _, key in
                        if key == .custom, model.config.voice.inputMethodKey.style == .hold {
                            model.update { $0.voice.inputMethodKey.style = .tap }
                        }
                    }
                }
                if model.config.voice.inputMethodKey.key == .custom {
                    RowDivider()
                    SettingRow("要模拟的快捷键", detail: "与输入工具里的设置一致，例如 Handy 的 Option + 空格。组合键在开始和结束时各按一次。") {
                        ShortcutRecorder(combo: model.binding(\.voice.inputMethodKey.custom))
                    }
                }
                RowDivider()
                SettingRow("怎么按") {
                    Picker("怎么按", selection: model.binding(\.voice.inputMethodKey.style)) {
                        ForEach(InputMethodKey.Style.allCases.filter {
                            model.config.voice.inputMethodKey.key != .custom || $0 != .hold
                        }, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                RowDivider()
                SettingRow("松手后多久切回麦克风", detail: "微信、豆包输入法需把各自的麦克风设为「自动检测」，才能跟随这里临时切麦。") {
                    SnapSlider(value: model.binding(\.voice.restoreInputDelay), in: 0...5, step: 0.5).frame(width: 180)
                    ValueChip(text: String(format: "%.1f 秒", model.config.voice.restoreInputDelay))
                }
            }
        }
    }

    private func checkModel() {
        guard #available(macOS 26, *) else { return }
        checking = true
        let locale = Locale(identifier: model.config.voice.localeID)
        Task {
            do {
                let status = try await SpeechAnalyzerTranscriber.prepare(locale: locale)
                withAnimation(Motion.pick(Motion.bounce)) { modelStatus = status }
            } catch {
                withAnimation(Motion.pick(Motion.bounce)) { modelStatus = "失败：\(error.localizedDescription)" }
            }
            checking = false
        }
    }

    private func chooseWhisperModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data, UTType(filenameExtension: "gguf") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.update { $0.voice.whisper.modelPath = url.path }
    }

    private func deleteWhisperModel() {
        guard let item = deletingModel else { return }
        deletingModel = nil
        do {
            try model.whisperModels.delete(item)
            deleteError = nil
        } catch {
            deleteError = "没删掉：\(error.localizedDescription)"
        }
    }
}

extension TranscriberChoice {
    /// 下拉菜单里的短名字（长的说明写在这一行的小字里）
    var shortTitle: String {
        switch self {
        case .automatic: return "自动"
        case .appleSpeech: return "系统转写"
        case .whisper: return "whisper.cpp"
        }
    }
}

/// 防吞字的时间线：按下前保留的一段（预热时）、按下、满长按时间才算数。珊瑚色那段跟着滑块伸缩。
struct PrebufferTimeline: View {
    let warm: Bool
    let warmSeconds: Double
    let threshold: Double

    var body: some View {
        GeometryReader { geometry in
            let span = 3.0 + 2.0
            let x = { (t: Double) in geometry.size.width * (t + 3.0) / span }
            let start = warm ? -warmSeconds : 0
            ZStack(alignment: .topLeading) {
                Capsule().fill(Color.primary.opacity(0.07)).frame(height: 14).offset(y: 22)
                Capsule().fill(Brand.coral).frame(width: max(6, x(2) - x(start)), height: 14).offset(x: x(start), y: 22)
                if warm {
                    Text("按键前保留 \(String(format: "%.1f", warmSeconds)) 秒").font(.caption2.weight(.medium)).foregroundStyle(Brand.coralText)
                        .offset(x: x(start), y: 2)
                        .transition(.opacity)
                }
                marker(x(0), "按下", color: .primary)
                marker(x(threshold), String(format: "满 %.2f 秒才算数", threshold), color: .secondary)
                Text(warm ? "按键前的声音也会算进去" : "按下的瞬间开始录，不会吞掉第一个字")
                    .font(.caption).foregroundStyle(.secondary).offset(y: 56)
            }
        }
        .animation(Motion.pick(Motion.bounce), value: warmSeconds)
        .animation(Motion.pick(Motion.bounce), value: warm)
    }

    private func marker(_ x: CGFloat, _ text: String, color: Color) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(color.opacity(0.7)).frame(width: 1.5, height: 26).offset(x: x, y: 16)
            Text(text).font(.caption2).foregroundStyle(color).fixedSize().offset(x: x + 4, y: 40)
        }
    }
}

/// 外部输入法模式下掌声做了什么：一排带图标的小步骤，箭头连着。
struct InputMethodFlow: View {
    let mic: String
    let key: String
    let style: InputMethodKey.Style

    var body: some View {
        let press = switch style {
        case .hold: "按住"
        case .tap: "按一下"
        case .doubleTap: "连按两下"
        }
        let steps: [(String, String, Color)] = [
            ("hand.point.up.left.fill", "按住遥控器", Brand.coralBottom), ("mic.fill", "切到\(mic)", .tileBlue),
            ("keyboard.fill", "替你\(press) \(key)", .tileIndigo), ("text.alignleft", "输入法出字", .tileGreen),
            ("arrow.uturn.backward", "切回原来的麦", .tileGray),
        ]
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 4) { flow(steps, vertical: false) }
            VStack(alignment: .leading, spacing: 6) { flow(steps, vertical: true) }
        }
    }

    @ViewBuilder
    private func flow(_ steps: [(String, String, Color)], vertical: Bool) -> some View {
        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
            if index > 0 && !vertical {
                Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary).padding(.top, 9)
            }
            if vertical {
                HStack(spacing: 8) {
                    IconTile(symbol: step.0, color: step.2, size: 22)
                    Text(step.1).font(.caption)
                }
            } else {
                VStack(spacing: 5) {
                    IconTile(symbol: step.0, color: step.2, size: 26)
                    Text(step.1).font(.caption).multilineTextAlignment(.center).fixedSize()
                }
                .frame(minWidth: 70)
                .staggerIn(index + 2, dy: 6)
            }
        }
    }
}

// MARK: - 权限

struct PermissionsPane: View {
    @Environment(AppModel.self) private var model

    private var allGranted: Bool { Permission.allCases.allSatisfy { model.permissions[$0] == true } }

    var body: some View {
        PaneScaffold(title: "权限", subtitle: "掌声只读按键、只在你按住时录音，都在这台 Mac 上处理，不上传。") {
            if allGranted {
                SettingsCard("\(Permission.allCases.count) 个权限都开了", subtitle: "能读按键、能录音、能把字贴到光标处。",
                             symbol: "checkmark", color: .tileGreen, highlighted: .tileGreen) {
                    VStack(spacing: 0) {
                        ForEach(Array(Permission.allCases.enumerated()), id: \.element) { index, permission in
                            if index > 0 { RowDivider() }
                            HStack(spacing: 12) {
                                IconTile(symbol: permission.symbol, color: permission.tileColor, size: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(permission.title)
                                    Text(permission.purpose).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "checkmark.circle.fill").font(.system(size: 16)).foregroundStyle(.white, Color.tileGreen)
                            }
                            .padding(.vertical, 8)
                        }
                    }
                }
                .staggerIn(1)
                .transition(.swapIn)
            } else {
                PermissionStack(expandsCurrent: true)
                    .staggerIn(1)
                    .transition(.swapIn)
            }
            Hint("点「开启」会打开系统设置，旁边浮出掌声的图标，把它拖进列表就行（麦克风是系统直接弹框问你）。打开后这里自动打勾，掌声会自动重新开始监听。",
                 symbol: "lightbulb")
                .padding(.horizontal, 4)
                .staggerIn(2)
        }
        .animation(Motion.pick(Motion.smooth), value: allGranted)
    }
}

// MARK: - Pro

struct ProPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PaneScaffold(title: "Pro", subtitle: "免费版已经能完整用「按键 → 说话 → 出字」，全部设备都能用。") {
            HStack(spacing: 18) {
                LogoMark(size: 76, interactive: false)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text("掌声 Pro").font(.system(size: 20, weight: .bold))
                        StatusPill(text: "1.0 正式版发布时开卖", color: Brand.coralText, symbol: "clock")
                    }
                    Text("一次买断，给多台设备、多个场景和录音剪辑。")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text("现在是\(model.engine.gate.editionName)").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(18)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Brand.coralTop.opacity(0.18), Color.tilePurple.opacity(0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Brand.coralTop.opacity(0.25), lineWidth: 0.5))
            .staggerIn(1)
            // 用 Grid 而不是 LazyVGrid：同一行的两张卡一样高
            let kinds = ProFeatureCard.Kind.allCases
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach(Array(stride(from: 0, to: kinds.count, by: 2)), id: \.self) { row in
                    GridRow {
                        ForEach(row..<min(row + 2, kinds.count), id: \.self) { index in
                            ProFeatureCard(kind: kinds[index]).staggerIn(index + 2)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 关于

struct AboutPane: View {
    @Environment(AppModel.self) private var model
    @State private var notice: String?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Spacer(minLength: 20)
                LogoMark(size: 124)
                    .staggerIn(0, dy: 0)
                Label("按住 Logo 试试", systemImage: "hand.point.up.left")
                    .font(.caption).foregroundStyle(.tertiary)
                    .padding(.top, 14)
                    .staggerIn(1)
                Text("掌声 VoxPalm").font(.system(size: 30, weight: .bold))
                    .padding(.top, 18)
                    .staggerIn(2)
                Text("按住说话，松手出字").font(.system(size: 15.5)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                    .staggerIn(3)
                HStack(spacing: 6) {
                    Chip(text: "版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")")
                    Chip(text: PrivateModules.buildFlavor)
                    Chip(text: model.engine.gate.editionName)
                }
                .padding(.top, 14)
                .staggerIn(4)
                HStack(spacing: 10) {
                    Button { model.openOnboarding() } label: { Label("重新打开引导", systemImage: "sparkles") }
                        .prominentButton()
                        .controlSize(.large)
                    Button { exportConfig() } label: { Label("导出设置…", systemImage: "square.and.arrow.up") }
                        .secondaryButton()
                        .controlSize(.large)
                    Button { importConfig() } label: { Label("导入设置…", systemImage: "square.and.arrow.down") }
                        .secondaryButton()
                        .controlSize(.large)
                }
                .padding(.top, 26)
                .staggerIn(5)
                if model.configProblem != nil, model.canRetryConfigSave {
                    Button("重试保存") { try? model.flushConfig() }
                        .secondaryButton().controlSize(.small).padding(.top, 10)
                }
                if let notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary).padding(.top, 10)
                        .transition(.swapIn)
                }
                if let backup = model.configBackupURL {
                    Button("在访达显示导入前的设置备份") {
                        NSWorkspace.shared.activateFileViewerSelecting([backup])
                    }
                    .font(.caption).buttonStyle(.link).padding(.top, 10)
                }
                Spacer(minLength: 20)
                Text("代码按 GPL-3.0-only 开源，内置的 whisper.cpp 按 MIT 许可；名字和图标是专有品牌素材。").font(.caption).foregroundStyle(.tertiary)
                    .padding(.bottom, 18)
                    .staggerIn(6)
            }
            .frame(maxWidth: .infinity)
            .containerRelativeFrame(.vertical)
        }
        .animation(Motion.pick(Motion.bounce), value: notice)
    }

    private func exportConfig() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "掌声设置.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportConfig(to: url)
            flash("已导出到「\(url.lastPathComponent)」")
        } catch {
            flash("导出失败：\(error.localizedDescription)", temporary: false)
        }
    }

    private func importConfig() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.importConfig(from: url)
            flash("已导入「\(url.lastPathComponent)」，原设置已备份")
        } catch {
            flash("导入失败：\(error.localizedDescription)", temporary: false)
        }
    }

    private func flash(_ text: String, temporary: Bool = true) {
        notice = text
        guard temporary else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { if notice == text { notice = nil } }
    }
}
