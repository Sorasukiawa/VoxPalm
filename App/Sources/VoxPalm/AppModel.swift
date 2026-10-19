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
    private(set) var devices: [ControlDevice] = []
    private(set) var micDevices: [AudioDeviceInfo] = []
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
    /// 正在学的键属于哪个流程（引导里学说话键时是 "onboarding"）
    private(set) var learnPurpose: String?

    /// 说话浮窗、菜单栏图标监听这些回调（AppDelegate 接上）
    @ObservationIgnored var onVoiceStateChange: ((VoiceSession.State) -> Void)?
    @ObservationIgnored var onVoiceOutcome: ((VoiceSession.Outcome) -> Void)?
    /// 打开设置、引导窗口（AppDelegate 接上；界面里调这两个）
    @ObservationIgnored var openSettingsHandler: ((SettingsPane?) -> Void)?
    @ObservationIgnored var openOnboardingHandler: (() -> Void)?

    @ObservationIgnored let engine: ButtonEngine
    @ObservationIgnored let voice: VoiceSession
    @ObservationIgnored private let audioWatcher = AudioWatcher()
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var permissionTimer: Timer?

    init() {
        PrivateModules.setUp()
        let config = AppConfig.load()
        self.config = config
        let sources: [ControlSource] = [HIDControlSource(), SystemKeysControlSource(), NowPlayingControlSource()] + PrivateModules.controlSources()
        engine = ButtonEngine(sources: sources, keyMap: config.keyMap)
        engine.timing = config.timing
        engine.textMethod = config.voice.textMethod
        voice = VoiceSession(settings: config.voice)
        engine.voice = voice
        wireCallbacks()
        refreshDevices()
        refreshPermissions()
        engine.activate(config.controlDeviceIDs)
        audioWatcher.onEvent = { [weak self] _, event in
            switch event {
            case .deviceAdded, .deviceRemoved, .defaultInputChanged: self?.refreshDevices()
            default: break
            }
        }
        audioWatcher.start()
        // 用户在系统设置里打开权限后，自动重新启用监听。
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshPermissions() }
        }
        log.info("掌声启动：\(PrivateModules.buildFlavor, privacy: .public)，控制设备 \(config.controlDeviceIDs.count) 台")
    }

    private func wireCallbacks() {
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
            log.debug("按键 \(event.button.rawValue, privacy: .public) \(event.phase.rawValue, privacy: .public)")
        }
        engine.onGesture = { [weak self] event, gesture, action in
            let name: String? = switch gesture {
            case .single: "单击"
            case .double: "双击"
            case .longBegan: "长按开始"
            case .longEnded: "长按结束"
            case .pressBegan, .pressEnded: nil
            }
            guard let name else { return }
            self?.lastGesture = "\(event.label) \(name)" + (action.map { " → \($0.title)" } ?? "（没有映射）")
            log.info("手势 \(event.button.rawValue, privacy: .public) \(name, privacy: .public) → \(action?.title ?? "无", privacy: .public)")
        }
        voice.onStateChange = { [weak self] state in
            guard let self else { return }
            self.voiceState = state
            switch state {
            case .armed: self.talkStartedAt = Date()
            case .listening: if self.talkStartedAt == nil { self.talkStartedAt = Date() }
            case .idle: self.talkStartedAt = nil; self.micLevel = 0
            case .transcribing: self.micLevel = 0
            }
            self.onVoiceStateChange?(state)
            log.info("语音状态 \(String(describing: state), privacy: .public)")
        }
        voice.onOutcome = { [weak self] outcome in
            self?.onVoiceOutcome?(outcome)
        }
        voice.onLevel = { [weak self] level in
            guard let self else { return }
            // 平滑一点，免得竖条抖得太厉害
            self.micLevel = self.micLevel * 0.4 + level * 0.6
        }
        voice.onMessage = { [weak self] text in
            self?.message = text
            log.info("语音 \(text, privacy: .public)")
        }
        voice.onTranscript = { [weak self] text in
            self?.lastTranscript = text
            self?.lastTranscriptAt = Date()
            log.info("出字 \(text.count) 个字")
        }
    }

    // MARK: - 设置

    func update(_ change: (inout AppConfig) -> Void) {
        var new = config
        change(&new)
        guard new != config else { return }
        let old = config
        config = new
        if new.keyMap != old.keyMap { engine.keyMap = new.keyMap }
        if new.timing != old.timing { engine.timing = new.timing }
        if new.voice != old.voice {
            voice.settings = new.voice
            engine.textMethod = new.voice.textMethod
        }
        if new.controlDeviceIDs != old.controlDeviceIDs, !isPaused { engine.activate(new.controlDeviceIDs) }
        scheduleSave()
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [config] in
            do {
                try config.save()
            } catch {
                log.error("保存设置失败：\(error.localizedDescription, privacy: .public)")
            }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func exportConfig(to url: URL) throws {
        try config.save(to: url)
    }

    func importConfig(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let imported = try JSONDecoder().decode(AppConfig.self, from: data)
        update { $0 = imported }
    }

    // MARK: - 设备

    func refreshDevices() {
        devices = engine.allDevices()
        micDevices = AudioDevices.inputs()
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
    }

    func diagram(for device: ControlDevice) -> ResolvedDiagram {
        let layout = config.deviceLayouts[device.id] ?? DeviceLayout()
        if let fixed = engine.diagram(for: device) {
            var buttons: [String: ButtonID] = [:]
            for spot in fixed.spots { if let button = layout.spotButtons[spot.id] ?? spot.button { buttons[spot.id] = button } }
            return ResolvedDiagram(diagram: fixed, buttons: buttons, isFixed: true, reportsRelease: device.reportsRelease && fixed.reportsRelease)
        }
        let base = layout.diagramID.flatMap(DeviceDiagram.choice(id:)) ?? DeviceDiagram.guess(for: device)
        let diagram = base.id == "generic"
            ? DeviceDiagram.generic(buttons: layout.learned.map { ($0.button, $0.label) }, reportsRelease: device.reportsRelease)
            : base
        var buttons: [String: ButtonID] = [:]
        for spot in diagram.spots { if let button = spot.button ?? layout.spotButtons[spot.id] { buttons[spot.id] = button } }
        return ResolvedDiagram(diagram: diagram, buttons: buttons, isFixed: false, reportsRelease: device.reportsRelease)
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
        engine.activate(paused ? [] : config.controlDeviceIDs)
    }

    func openSettings(_ pane: SettingsPane? = nil) { openSettingsHandler?(pane) }
    func openOnboarding() { openOnboardingHandler?() }

    func finishOnboarding() {
        update { $0.onboardingDone = true }
    }

    /// 当前的说话键，例如「长按 确认键 说话」
    struct TalkKey {
        let gesture: GestureKind
        let keyName: String
        let action: Action
        var verb: String { action == .pushToTalk && gesture == .long ? "说话" : "开始 / 结束说话" }
        var releaseHint: String { action == .pushToTalk && gesture == .long ? "松开「\(keyName)」出字" : "再按一下「\(keyName)」出字" }
    }

    var talkKey: TalkKey? {
        let bindings = config.keyMap.bindings
        let pick = bindings.first { $0.action == .pushToTalk && $0.gesture == .long }
            ?? bindings.first { $0.action.isVoice }
            ?? bindings.first { $0.talkAfter == true }
        guard let pick else { return nil }
        return TalkKey(gesture: pick.gesture, keyName: pick.buttonLabel, action: pick.action)
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
    }

    var attentions: [Attention] {
        var items: [Attention] = []
        for permission in missingPermissions {
            items.append(Attention(id: permission.id, title: "还差「\(permission.title)」权限", detail: permission.consequence, fix: .permissions))
        }
        if config.controlDeviceIDs.isEmpty {
            items.append(Attention(id: "no-device", title: "还没选控制设备", detail: "选一个遥控器、无线麦或者媒体键，才能按键说话。", fix: .devices))
        } else if !activeDeviceConnected {
            items.append(Attention(id: "disconnected", title: "控制设备没连上", detail: "先在系统的蓝牙设置里连上它。", fix: .devices))
        }
        return items
    }

    // MARK: - 调试（渲染界面预览用）

    func simulate(voiceState: VoiceSession.State, level: Float = 0, startedAgo: Double = 4) {
        self.voiceState = voiceState
        micLevel = level
        talkStartedAt = voiceState == .idle ? nil : Date().addingTimeInterval(-startedAgo)
    }

    func simulate(transcript: String) {
        lastTranscript = transcript
        lastTranscriptAt = Date()
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
            engine.activate(config.controlDeviceIDs)
        }
    }

    var missingPermissions: [Permission] {
        Permission.allCases.filter { permissions[$0] != true && ($0 != .microphone || config.voice.mode == .builtIn) }
    }

    // MARK: - 调试

    /// 不按键直接试一次转写（菜单里的「试一下」）：开始 3 秒后结束。
    func tryVoice() {
        voice.voiceBegin(VoiceRequest())
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.voice.voiceEnd() }
    }

    /// 面板上「按住试一下」：按下开麦，松手出字（不管说话键是哪个）。
    func tryPress(_ down: Bool) {
        if down {
            voice.voiceArm(VoiceRequest())
            voice.voiceBegin(VoiceRequest())
        } else {
            voice.voiceEnd()
        }
    }
}
