import AppKit
import Observation
import os
import VoxPalmDevices
import VoxPalmEngine
import VoxPalmVoice

let log = Logger(subsystem: "com.sorasukiawa.VoxPalm", category: "app")

/// App 的全部状态。按键引擎、语音会话的回调都在主线程，这里统一更新界面。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    private(set) var config: AppConfig
    /// 读写设置失败时持续显示，不能只写日志后让用户以为已经保存。
    private(set) var configProblem: String?
    private(set) var configBackupURL: URL?
    private(set) var devices: [ControlDevice] = []
    private(set) var micDevices: [AudioDeviceInfo] = []
    /// 控制设备连着但用不了的原因（适配模块报的，比如 DJI 接管按键失败）；面板顶上显示成提醒
    private(set) var controlProblem: String?
    /// 控制设备接管按键时会被静音的收音设备（音频设备 UID）：录音避开它们，改用 Mac 麦
    private(set) var mutedMicUIDs: Set<String> = []
    /// 别的程序正开着被静音的那支麦（比如系统设置的「声音」页）：面板提醒是哪个程序
    private(set) var micHolders: [AudioInputClient] = []
    /// 需要提醒检查独立麦克风设置的输入法；能否跟随系统取决于输入法里的实际选择。
    private(set) var inputMethodIgnoringMic: String?
    private(set) var voiceState: VoiceSession.State = .idle
    private(set) var lastButton: String?
    private(set) var lastGesture: String?
    private(set) var lastTranscript: String?
    private(set) var message: String?
    private(set) var permissions: [Permission: Bool] = [:]
    private(set) var isLearning = false
    /// 正在被按住的键（示意图上高亮），一次性触发的键亮一下就灭
    private(set) var pressedButtons: Set<ButtonID> = []
    /// 正在学键的示意图位置（spot id；通用外形加新键、或者图上没有的键时是 "+"）
    private(set) var learningSpot: String?
    /// 暂停监听：掌声不读按键，遥控器照常控制别的 App
    private(set) var isPaused = false
    /// 录音时的音量（0…1）
    private(set) var micLevel: Float = 0
    /// 这次说话从什么时候开始（按下的瞬间），浮窗和面板的计时用
    private(set) var talkStartedAt: Date?
    private(set) var lastTranscriptAt: Date?
    /// 说话时的实时预览：这次到目前为止转出来的字（还会变、标点不全；whisper.cpp 没有预览，一直是空的）
    private(set) var liveTranscript = ""
    /// 正在学的键属于哪个流程（引导里学说话键时是 "onboarding"）
    private(set) var learnPurpose: String?
    /// 最近出的字（最多 3 条，只记在这次运行里，退出就清）
    private(set) var recentTranscripts: [TranscriptRecord] = []
    /// 最近一次字贴进去的时间：菜单栏图标两行字刷一下
    private(set) var lastInsertedAt: Date?
    @ObservationIgnored private var pendingApp: String?

    struct TranscriptRecord: Identifiable, Equatable {
        let id = UUID()
        let text: String
        /// 贴到了哪个 App；nil 表示放进了剪贴板
        let app: String?
        let at: Date
    }

    /// 说话浮窗、菜单栏图标监听这些回调（AppDelegate 接上）
    @ObservationIgnored var onVoiceStateChange: ((VoiceSession.State) -> Void)?
    @ObservationIgnored var onVoiceOutcome: ((VoiceSession.Outcome) -> Void)?
    /// 按键提示（说话浮窗接上）
    @ObservationIgnored var onKeyFlash: ((KeyFlash) -> Void)?
    /// 打开设置、引导窗口（AppDelegate 接上；界面里调这两个）
    @ObservationIgnored var openSettingsHandler: ((SettingsPane?) -> Void)?
    @ObservationIgnored var closePanelHandler: (() -> Void)?
    @ObservationIgnored var openOnboardingHandler: (() -> Void)?

    @ObservationIgnored let engine: ButtonEngine
    @ObservationIgnored let voice: VoiceSession
    /// whisper.cpp 模型的下载状态（设置页的 whisper.cpp 卡片、面板的提醒用）
    let whisperModels = WhisperModels()
    @ObservationIgnored private let audioWatcher = AudioWatcher()
    @ObservationIgnored private let configStore: AppConfigStore
    /// 截图也会实例化 AppModel，但只能读设备清单，不能接管真实按键或开麦。
    @ObservationIgnored private let isPreview = UIPreview.isRendering
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var inputSourceObserver: NSObjectProtocol?

    init() {
        PrivateModules.setUp()
        let store = AppConfigStore()
        configStore = store
        let config = store.initialConfig
        self.config = config
        configProblem = store.loadProblem
        // 下载的 whisper.cpp 模型放在配置文件旁边：用 VOXPALM_CONFIG 调试时跟着测试配置走
        WhisperModel.directory = AppConfig.fileURL.deletingLastPathComponent().appendingPathComponent("Models", isDirectory: true)
        whisperModels.refresh()
        let sources: [ControlSource] = [HIDControlSource(), SystemKeysControlSource(), NowPlayingControlSource()] + PrivateModules.controlSources()
        engine = ButtonEngine(sources: sources, keyMap: config.keyMap)
        engine.timing = config.timing
        engine.textMethod = config.voice.textMethod
        voice = VoiceSession(settings: Self.runtimeVoiceSettings(config.voice, isPreview: isPreview))
        engine.voice = voice
        store.onSaveResult = { [weak self] problem in
            self?.configProblem = problem
            if let problem { log.error("保存设置失败：\(problem, privacy: .public)") }
        }
        wireCallbacks()
        refreshDevices()
        refreshPermissions()
        activateEngine(config.controlDeviceIDs)
        audioWatcher.onEvent = { [weak self] _, event in
            switch event {
            case .deviceAdded, .deviceRemoved, .defaultInputChanged: self?.refreshDevices()
            default: break
            }
        }
        audioWatcher.start()
        refreshInputMethod()
        inputSourceObserver = DistributedNotificationCenter.default().addObserver(forName: InputMethodMic.enabledChangedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInputMethod() }
        }
        // 用户在系统设置里打开权限后，自动重新启用监听。
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissions()
                // 选设备时新连上的蓝牙设备要及时出现在列表里
                if self?.isIdentifying == true { self?.refreshDevices() }
                if self?.panelVisible == true { self?.refreshMicHolders() }
            }
        }
        // 晚一点没关系：让系统把这次唤醒和别的合在一起
        permissionTimer?.tolerance = 0.5
        log.info("掌声启动：\(PrivateModules.buildFlavor, privacy: .public)，控制设备 \(config.controlDeviceIDs.count) 台")
        if isPreview { log.info("界面预览模式：不启用控制设备或录音") }
    }

    private func wireCallbacks() {
        let debug = self.debugMutedMic
        voice.mutedInputs = { [weak engine = self.engine] in engine.map { Self.mutedInputs($0, debug: debug) } ?? [] }
        for source in engine.sources {
            source.onDevicesChanged = { [weak self] in self?.refreshDevices() }
        }
        engine.onMessage = { [weak self] text in
            self?.message = text
            log.info("动作 \(text, privacy: .public)")
        }
        engine.onButtonEvent = { [weak self] event in
            self?.highlight(event)
            self?.lastButton = "\(event.label) \(event.phase == .down ? "按下" : event.phase == .up ? "松开" : "触发")"
            // 「键盘按键」来源看得到用户打的每个键：没映射的键不写日志
            guard event.deviceID != SystemKeysControlSource.keyboardDeviceID || self?.config.keyMap.isMapped(event.button) == true else { return }
            log.debug("按键 \(event.button.rawValue, privacy: .public) \(event.phase.rawValue, privacy: .public)")
        }
        engine.onInputCancelled = { [weak self] id in
            guard let self, self.config.controlDeviceIDs.contains(id) else { return }
            self.pressedButtons.removeAll()
        }
        engine.onGesture = { [weak self] event, gesture, action in
            let name: String? = switch gesture {
            case .single: "单击"
            case .double: "双击"
            case .longBegan: "长按开始"
            case .longEnded: "长按结束"
            case .pressBegan, .pressEnded: nil
            }
            guard let name, action != nil || event.deviceID != SystemKeysControlSource.keyboardDeviceID else { return }
            self?.lastGesture = "\(event.label) \(name)" + (action.map { " → \($0.title)" } ?? "（没有映射）")
            log.info("手势 \(event.button.rawValue, privacy: .public) \(name, privacy: .public) → \(action?.title ?? "无", privacy: .public)")
            self?.flashKey(event, gesture: gesture, action: action)
        }
        voice.onStateChange = { [weak self] state in
            guard let self else { return }
            self.voiceState = state
            switch state {
            case .armed: self.talkStartedAt = Date(); self.liveTranscript = ""
            case .listening: if self.talkStartedAt == nil { self.talkStartedAt = Date() }
            case .idle: self.talkStartedAt = nil; self.micLevel = 0
            case .transcribing: self.micLevel = 0
            }
            self.onVoiceStateChange?(state)
            log.info("语音状态 \(String(describing: state), privacy: .public)")
        }
        voice.onOutcome = { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case let .inserted(_, app):
                self.pendingApp = app ?? "光标处"
                self.lastInsertedAt = Date()
            case let .copied(_, reason):
                self.pendingApp = nil
                log.info("没贴，字放进剪贴板：\(reason.pasteMessage, privacy: .public)")
            default:
                break
            }
            self.onVoiceOutcome?(outcome)
        }
        voice.onLevel = { [weak self] level in
            // 只有说话时有地方画音量；「一直开着麦」时平常也每秒报 20 次，不用去刷界面
            guard let self, self.voiceState == .armed || self.voiceState == .listening else { return }
            // 平滑一点，免得竖条抖得太厉害
            self.micLevel = self.micLevel * 0.4 + level * 0.6
        }
        voice.onPartial = { [weak self] text in
            guard let self, self.voiceState == .listening || self.voiceState == .transcribing else { return }
            self.liveTranscript = text
        }
        voice.onMessage = { [weak self] text in
            self?.message = text
            log.info("语音 \(text, privacy: .public)")
        }
        voice.onTranscript = { [weak self] text in
            guard let self else { return }
            self.lastTranscript = text
            self.lastTranscriptAt = Date()
            self.recentTranscripts.insert(TranscriptRecord(text: text, app: self.pendingApp, at: Date()), at: 0)
            if self.recentTranscripts.count > 3 { self.recentTranscripts.removeLast(self.recentTranscripts.count - 3) }
            log.info("出字 \(text.count) 个字")
        }
    }

    // MARK: - 设置

    func update(_ change: (inout AppConfig) -> Void) {
        var new = config
        change(&new)
        apply(new, save: true)
    }

    private func apply(_ new: AppConfig, save: Bool) {
        guard new != config else { return }
        let old = config
        config = new
        if new.keyMap != old.keyMap { engine.keyMap = new.keyMap }
        if new.timing != old.timing { engine.timing = new.timing }
        if new.voice != old.voice {
            voice.settings = Self.runtimeVoiceSettings(new.voice, isPreview: isPreview)
            engine.textMethod = new.voice.textMethod
        }
        if new.controlDeviceIDs != old.controlDeviceIDs {
            pressedButtons.removeAll()
            if !isPaused { activateEngine(new.controlDeviceIDs) }
        }
        if save, !isPreview { configStore.scheduleSave(config) }
    }

    /// 退出前同步写入最后一次修改，也供设置页主动重试。
    func flushConfig() throws {
        try configStore.flush()
    }

    var canRetryConfigSave: Bool { configStore.hasPendingChanges && configStore.loadProblem == nil }

    /// 界面照样显示用户选项，只禁止预览进程实际预热麦克风。
    static func runtimeVoiceSettings(_ settings: VoiceSession.Settings, isPreview: Bool) -> VoiceSession.Settings {
        var runtime = settings
        if isPreview { runtime.keepMicWarm = false }
        return runtime
    }

    /// 导出的文件不含设备身份，见 `AppConfig.sharable`
    func exportConfig(to url: URL) throws {
        try config.sharable().save(to: url)
    }

    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        var imported = try AppConfig.decode(data)
        _ = imported.resolveDevicePlaceholders(connected: engine.allDevices().map(\.id))
        configBackupURL = try configStore.replace(with: imported, previous: config)
        apply(imported, save: false)
    }

    // MARK: - 设备

    func refreshDevices() {
        devices = engine.allDevices()
        // 导入时没连着的设备，连上后再认回
        let connected = devices.map(\.id)
        update { _ = $0.resolveDevicePlaceholders(connected: connected) }
        micDevices = AudioDevices.inputs()
        if !isPreview { voice.inputDevicesChanged() }
        let problem = activeDevice.flatMap { engine.problem(of: $0.id) }
        if problem != controlProblem {
            controlProblem = problem
            if let problem { log.notice("控制设备出问题：\(problem, privacy: .public)") }
        }
        refreshMuted()
    }

    /// 启用控制设备，顺便更新它会静音哪些麦
    private func activateEngine(_ ids: [String]) {
        guard !isPreview else { return }
        // 还没认回的导入标识不是真设备，不交给适配模块
        engine.activate(ids.filter { !$0.contains(Redaction.identityPlaceholder) })
        refreshMuted()
    }

    /// 调试：把这支麦当成会被控制设备静音（环境变量 VOXPALM_DEBUG_MUTED_MIC=音频设备 UID），没有那种无线麦也能测换麦和提醒
    @ObservationIgnored private let debugMutedMic = ProcessInfo.processInfo.environment["VOXPALM_DEBUG_MUTED_MIC"].flatMap { $0.isEmpty ? nil : $0 }

    /// 启用着的控制设备会静音的麦（录音和界面用同一份）
    nonisolated private static func mutedInputs(_ engine: ButtonEngine, debug: String?) -> Set<String> {
        var muted = engine.mutedInputs()
        if let debug, !engine.activeDeviceIDs.isEmpty { muted.insert(debug) }
        return muted
    }

    private func refreshMuted() {
        let muted = Self.mutedInputs(engine, debug: debugMutedMic)
        guard muted != mutedMicUIDs else { return }
        mutedMicUIDs = muted
        refreshMicHolders()
    }

    /// 菜单栏面板开着没有（StatusItemController 设）。占麦的提醒只在面板上显示，面板开着时才去查
    @ObservationIgnored var panelVisible = false {
        didSet { if panelVisible && !oldValue { refreshMicHolders() } }
    }

    /// 看看有没有别的程序开着被静音的那支麦（只在有要避开的麦时查）。要翻 Core Audio 的整张进程表，
    /// 一次 7 毫秒左右，以前每 2 秒在主线程查一次；现在只在面板打开时和开着时每 2 秒查一次，要避开的麦变了也查一次
    private func refreshMicHolders() {
        let holders = micDevices.filter { mutedMicUIDs.contains($0.uid) }.flatMap { AudioDevices.inputClients(of: $0.id) }
        guard holders != micHolders else { return }
        micHolders = holders
        if !holders.isEmpty {
            let names = holders.map { "\($0.name)（\($0.bundleID ?? "?")，进程 \($0.pid)）" }.joined(separator: "、")
            log.notice("被控制设备静音的麦正被别的程序开着：\(names, privacy: .public)")
        }
    }

    /// 提醒条上的「重试」：让适配模块重新接管控制设备
    func retryControlDevice() {
        guard !isPreview else { return }
        guard let id = activeDevice?.id else { return }
        engine.retry(id)
    }

    var activeDevice: ControlDevice? {
        devices.first { config.controlDeviceIDs.contains($0.id) }
    }

    var activeDeviceStatus: String? {
        activeDevice.flatMap { engine.status(of: $0.id) }
    }

    var selectedMic: AudioDeviceInfo? {
        if let uid = config.voice.micUID { return micDevices.first { $0.uid == uid } }
        return micDevices.first(where: \.isDefaultInput)
    }

    /// 录音实际用哪支麦：选的那支（或跟随的系统默认输入）会被控制设备静音时，换成 Mac 麦（见 MicRouting）
    var micRoute: MicRouting.Route {
        MicRouting.resolve(selectedUID: config.voice.micUID, inputs: micDevices, muted: mutedMicUIDs)
    }

    /// 这次录音真正用的麦
    var recordingMic: AudioDeviceInfo? {
        micRoute.device ?? selectedMic
    }

    /// 外部输入法模式下选择外接麦时，提醒检查输入法自己的麦克风设置，不推断它当前实际用了哪支麦。
    var inputMethodMicWarning: (ime: String, mic: String)? {
        guard config.voice.mode == .inputMethod, let ime = inputMethodIgnoringMic,
              let mic = recordingMic, mic.transport != "Built-in" else { return nil }
        return (ime, micShortName(mic))
    }

    private func refreshInputMethod() {
        let name = InputMethodMic.enabledIgnoringDefaultInput()
        if name != inputMethodIgnoringMic { inputMethodIgnoringMic = name }
    }

    func selectControlDevice(_ id: String?) {
        update { $0.controlDeviceIDs = id.map { [$0] } ?? [] }
    }

    // MARK: - 示意图和学键

    /// 某台设备现在用的示意图，以及图上每个位置对应的键。
    struct ResolvedDiagram {
        var diagram: DeviceDiagram
        var buttons: [String: ButtonID]
        /// 外形是适配模块给的（比如 DJI），不能改
        var isFixed: Bool
        var reportsRelease: Bool
        /// 快速连按两下能不能分别报出来（有的无线麦接管后快速连按两下报不出来，做不了双击）
        var allowsDouble = true

        /// 这台设备能不能做这个手势
        func allows(_ gesture: GestureKind) -> Bool {
            switch gesture {
            case .single: return true
            case .double: return allowsDouble
            case .long: return reportsRelease
            }
        }
    }

    func diagram(for device: ControlDevice) -> ResolvedDiagram {
        let layout = config.deviceLayouts[device.id] ?? DeviceLayout()
        if let fixed = engine.diagram(for: device) {
            var buttons: [String: ButtonID] = [:]
            for spot in fixed.spots { if let button = layout.spotButtons[spot.id] ?? spot.button { buttons[spot.id] = button } }
            return ResolvedDiagram(diagram: fixed, buttons: buttons, isFixed: true, reportsRelease: device.reportsRelease && fixed.reportsRelease,
                                   allowsDouble: engine.reportsDoubleTap(device.id))
        }
        let base = layout.diagramID.flatMap(DeviceDiagram.choice(id:)) ?? DeviceDiagram.guess(for: device)
        let diagram = base.id == "generic"
            ? DeviceDiagram.generic(buttons: layout.learned.map { ($0.button, $0.label) }, reportsRelease: device.reportsRelease)
            : base
        var buttons: [String: ButtonID] = [:]
        for spot in diagram.spots { if let button = spot.button ?? layout.spotButtons[spot.id] { buttons[spot.id] = button } }
        return ResolvedDiagram(diagram: diagram, buttons: buttons, isFixed: false, reportsRelease: device.reportsRelease,
                               allowsDouble: engine.reportsDoubleTap(device.id))
    }

    func setDiagram(_ diagramID: String?, for deviceID: String) {
        update { $0.deviceLayouts[deviceID, default: DeviceLayout()].diagramID = diagramID }
    }

    /// 学示意图上某个位置对应的键；spotID 传 "+" 表示给通用外形加一个新键。
    func startLearning(spot spotID: String, purpose: String? = nil, completion: ((ButtonEvent) -> Void)? = nil) {
        guard let device = activeDevice else {
            message = "先选一个控制设备"
            return
        }
        learningSpot = spotID
        learnPurpose = purpose
        engine.learnHandler = { [weak self] event in
            guard let self else { return }
            self.learningSpot = nil
            self.learnPurpose = nil
            defer { completion?(event) }
            // 学到的键已经在图上（适配模块知道键值、或者之前对上过）就不用再记。
            if spotID == "+", self.diagram(for: device).buttons.values.contains(event.button) { return }
            self.update { config in
                var layout = config.deviceLayouts[device.id] ?? DeviceLayout()
                if spotID == "+" {
                    if !layout.learned.contains(where: { $0.button == event.button }) {
                        layout.learned.append(LearnedButton(button: event.button, label: event.label))
                    }
                } else {
                    layout.spotButtons[spotID] = event.button
                }
                config.deviceLayouts[device.id] = layout
            }
            self.message = "学到了：\(event.label)"
        }
    }

    /// 引导选设备那步：按一下任意一台设备就认出来（引擎同时听所有 HID 设备和媒体键，不执行动作）。
    func startIdentifying(_ handler: @escaping (ControlDevice) -> Void) {
        guard !isPreview else { return }
        engine.identifyHandler = { [weak self] event in
            guard let self else { return }
            self.highlight(event)
            if !self.devices.contains(where: { $0.id == event.deviceID }) { self.refreshDevices() }
            if let device = self.devices.first(where: { $0.id == event.deviceID }) { handler(device) }
        }
        refreshDevices()
    }

    func stopIdentifying() {
        engine.identifyHandler = nil
    }

    var isIdentifying: Bool { engine.identifyHandler != nil }

    func cancelLearning() {
        learningSpot = nil
        learnPurpose = nil
        engine.learnHandler = nil
    }

    func forgetSpot(_ spotID: String, deviceID: String) {
        update { config in
            config.deviceLayouts[deviceID]?.spotButtons[spotID] = nil
            config.deviceLayouts[deviceID]?.learned.removeAll { $0.button.rawValue == spotID }
        }
    }

    func binding(for button: ButtonID, gesture: GestureKind) -> KeyBinding? {
        config.keyMap.binding(for: button, gesture: gesture)
    }

    func setBinding(_ binding: KeyBinding) {
        update { $0.keyMap.set(binding) }
    }

    func removeBinding(button: ButtonID, gesture: GestureKind) {
        update { $0.keyMap.bindings.removeAll { $0.button == button && $0.gesture == gesture } }
    }

    func removeBinding(_ id: UUID) {
        update { $0.keyMap.bindings.removeAll { $0.id == id } }
    }

    /// 按键提示：平时按控制设备上的键，屏幕下方弹一张小卡片，设备图上点亮这个键，写清楚做了什么，
    /// 一眼看出连对了没有、设对了没有。说话类的动作有说话浮窗，不再弹；「键盘按键」看得到用户打的每个键，没设动作的不弹。
    private func flashKey(_ event: ButtonEvent, gesture: RecognizedGesture, action: Action?) {
        guard config.showKeyFlash, !isPaused, learningSpot == nil else { return }
        let gestureName: String
        switch gesture {
        case .single: gestureName = "单击"
        case .double: gestureName = "双击"
        case .longBegan: gestureName = "长按"
        default: return
        }
        if action?.isVoice == true { return }
        if action == nil, event.deviceID == SystemKeysControlSource.keyboardDeviceID { return }
        guard let device = devices.first(where: { $0.id == event.deviceID }) else { return }
        let resolved = diagram(for: device)
        let spot = resolved.buttons.first { $0.value == event.button }?.key
        let name = spot.flatMap { id in resolved.diagram.spots.first { $0.id == id }?.name } ?? event.label
        let shortName = name.replacingOccurrences(of: #"（.*）"#, with: "", options: .regularExpression)
        onKeyFlash?(KeyFlash(diagram: resolved.diagram, spot: spot, title: "\(shortName) · \(gestureName)",
                             detail: action.map { "→ \($0.title)" } ?? "这个手势还没设动作，点菜单栏图标去设置", bound: action != nil))
    }

    private func highlight(_ event: ButtonEvent) {
        switch event.phase {
        case .down:
            pressedButtons.insert(event.button)
        case .up:
            pressedButtons.remove(event.button)
        case .trigger:
            pressedButtons.insert(event.button)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in self?.pressedButtons.remove(event.button) }
        }
    }

    // MARK: - 面板、浮窗用的说明

    func setPaused(_ paused: Bool) {
        isPaused = paused
        activateEngine(paused ? [] : config.controlDeviceIDs)
    }

    /// 打开设置时直接定位到要改的那一项：按键页弹出某个键的编辑小窗、设备页切到收音设备。
    struct SettingsFocus: Equatable {
        var editSpot: String?
        var showsMics = false
        let id = UUID()
    }

    private(set) var settingsFocus: SettingsFocus?

    func openSettings(_ pane: SettingsPane? = nil, focus: SettingsFocus? = nil) {
        settingsFocus = focus
        openSettingsHandler?(pane)
    }

    func consumeSettingsFocus() { settingsFocus = nil }
    func closePanel() { closePanelHandler?() }
    func openOnboarding() { openOnboardingHandler?() }

    func finishOnboarding() {
        update { $0.onboardingDone = true }
    }

    /// 当前的说话键，例如「长按 确认键 说话」
    struct TalkKey {
        let gesture: GestureKind
        let keyName: String
        let action: Action
        let button: ButtonID
        var verb: String { action == .pushToTalk && gesture == .long ? "说话" : "开始 / 结束说话" }
        var releaseHint: String { action == .pushToTalk && gesture == .long ? "松开「\(keyName)」出字" : "再按一下「\(keyName)」出字" }
    }

    var talkKey: TalkKey? {
        let bindings = config.keyMap.bindings
        let pick = bindings.first { $0.action == .pushToTalk && $0.gesture == .long }
            ?? bindings.first { $0.action.isVoice }
            ?? bindings.first { $0.talkAfter == true }
        guard let pick else { return nil }
        return TalkKey(gesture: pick.gesture, keyName: pick.buttonLabel, action: pick.action, button: pick.button)
    }

    /// 说话键在示意图上是哪个位置（面板点键名时，设置的按键页直接弹出它的编辑小窗）
    var talkSpotID: String? {
        guard let key = talkKey, let device = activeDevice else { return nil }
        return diagram(for: device).buttons.first { $0.value == key.button }?.key
    }

    /// 控制设备现在连着没有（列表里找得到就算连着）
    var activeDeviceConnected: Bool {
        guard let id = config.controlDeviceIDs.first else { return false }
        return devices.contains { $0.id == id }
    }

    var activeDeviceName: String? {
        activeDevice?.name ?? config.controlDeviceIDs.first.map { _ in "已选的设备" }
    }

    var outputSummary: String {
        switch config.voice.mode {
        case .builtIn:
            let names = ["zh-CN": "普通话", "zh-TW": "国语", "yue-CN": "粤语", "en-US": "英语", "ja-JP": "日语"]
            return "内置转写 · " + (names[config.voice.localeID] ?? config.voice.localeID)
        case .inputMethod:
            return "外部输入法 · " + config.voice.inputMethodKey.key.title
        }
    }

    /// 需要用户处理的事，面板顶上的提示条按顺序显示第一条
    struct Attention: Identifiable {
        let id: String
        let title: String
        let detail: String
        let fix: SettingsPane
        /// 缺权限的提醒：点「开启」直接走授权小窗
        var permission: Permission?
        /// 控制设备接管失败的提醒：点「重试」重新接管
        var retry = false
        /// 只是告诉一声、不用处理（不带按钮，菜单栏图标也不变成「要处理」）
        var informational = false
    }

    var attentions: [Attention] {
        var items: [Attention] = []
        if configProblem != nil {
            items.append(Attention(id: "config-storage", title: "设置还没有保存",
                                   detail: "请到设置 › 关于查看原因，重试保存或导出备份。", fix: .about))
        }
        for permission in missingPermissions {
            items.append(Attention(id: permission.id, title: "还差「\(permission.title)」权限", detail: permission.consequence, fix: .permissions, permission: permission))
        }
        if config.controlDeviceIDs.isEmpty {
            items.append(Attention(id: "no-device", title: "还没选控制设备", detail: "选一个遥控器、无线麦或者媒体键，才能按键说话。", fix: .devices))
        } else if !activeDeviceConnected {
            items.append(Attention(id: "disconnected", title: "控制设备没连上", detail: "先在系统的蓝牙设置里连上它。", fix: .devices))
        } else if let controlProblem, !isPaused {
            items.append(Attention(id: "control-problem", title: "\(activeShortName ?? "控制设备")的按键没接上", detail: controlProblem, fix: .devices, retry: true))
        }
        if config.voice.mode == .builtIn, TranscriberFactory.usesWhisper(config.voice.transcriber), !whisperModels.isReady(config.voice.whisper) {
            let whisper = config.voice.whisper
            items.append(Attention(id: "whisper-model", title: whisper.usesCustomFile ? "还没选语音模型文件" : "还没下载语音模型",
                                   detail: whisper.usesCustomFile ? "内置转写用 whisper.cpp，在设置 › 语音里选一个 ggml 模型文件。"
                                       : "内置转写用 whisper.cpp，先在设置 › 语音里下载「\(whisper.model.title)」模型（\(whisper.model.sizeText)）才能出字。",
                                   fix: .voice))
        }
        if !isPaused, let holder = micHolders.first, let mic = micDevices.first(where: { mutedMicUIDs.contains($0.uid) }) {
            let fallback = MicRouting.resolve(selectedUID: mic.uid, inputs: micDevices, muted: mutedMicUIDs).device.map(micShortName) ?? "别的麦"
            items.append(Attention(id: "mic-held", title: "「\(holder.name)」开着 \(micShortName(mic)) 的麦",
                                   detail: "现在收音用 \(fallback)，不影响说话。以后要同时用它的按键和麦，得先关掉这个程序。",
                                   fix: .devices, informational: true))
        }
        if !isPaused, let warning = inputMethodMicWarning {
            items.append(Attention(id: "ime-mic", title: "检查\(warning.ime)的麦克风设置",
                                   detail: "要用 \(warning.mic) 收音，请确认输入法自己的麦克风已设为「自动检测」；固定选择某支麦时不会跟随掌声切换。",
                                   fix: .voice, informational: true))
        }
        return items
    }

    /// 有要用户动手处理的事（只是告诉一声的不算）：菜单栏图标和面板状态写「要处理」
    var needsAttention: Bool { attentions.contains { !$0.informational } }

    // MARK: - 调试（渲染界面预览用）

    func simulate(voiceState: VoiceSession.State, level: Float = 0, startedAgo: Double = 4) {
        self.voiceState = voiceState
        micLevel = level
        talkStartedAt = voiceState == .idle ? nil : Date().addingTimeInterval(-startedAgo)
    }

    func simulate(transcript: String, app: String? = "备忘录", ago: Double = 0) {
        lastTranscript = transcript
        lastTranscriptAt = Date()
        recentTranscripts.insert(TranscriptRecord(text: transcript, app: app, at: Date().addingTimeInterval(-ago)), at: 0)
        if recentTranscripts.count > 3 { recentTranscripts.removeLast(recentTranscripts.count - 3) }
    }

    func simulate(paused: Bool) {
        isPaused = paused
    }

    // MARK: - 权限

    func refreshPermissions() {
        var current: [Permission: Bool] = [:]
        for permission in Permission.allCases { current[permission] = permission.isGranted }
        guard current != permissions else { return }
        let gainedInput = current[.inputMonitoring] == true && permissions[.inputMonitoring] == false
        let gainedAccessibility = current[.accessibility] == true && permissions[.accessibility] == false
        permissions = current
        if gainedInput || gainedAccessibility, !isPaused {
            activateEngine(config.controlDeviceIDs)
        }
    }

    var missingPermissions: [Permission] {
        Permission.allCases.filter { permissions[$0] != true && ($0 != .microphone || config.voice.mode == .builtIn) }
    }

    // MARK: - 调试

    /// 不按键直接试一次转写（菜单里的「试一下」）：开始 3 秒后结束。
    func tryVoice() {
        guard !isPreview else { return }
        voice.voiceBegin(VoiceRequest())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.voice.voiceEnd() }
    }

    /// 面板上「按住试一下」：按下开麦，松手出字（不管说话键是哪个）。
    func tryPress(_ down: Bool) {
        guard !isPreview else { return }
        if down {
            voice.voiceArm(VoiceRequest())
            voice.voiceBegin(VoiceRequest())
        } else {
            voice.voiceEnd()
        }
    }
}
