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
    /// 学键学到的键，等用户在设置里选手势和动作
    var learned: ButtonEvent?

    @ObservationIgnored let engine: ButtonEngine
    @ObservationIgnored let voice: VoiceSession
    @ObservationIgnored private let audioWatcher = AudioWatcher()
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private var permissionTimer: Timer?

    init() {
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
        engine.onButtonEvent = { [weak self] event in
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
            self?.voiceState = state
            log.info("语音状态 \(String(describing: state), privacy: .public)")
        }
        voice.onMessage = { [weak self] text in
            self?.message = text
            log.info("语音 \(text, privacy: .public)")
        }
        voice.onTranscript = { [weak self] text in
            self?.lastTranscript = text
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
        if new.controlDeviceIDs != old.controlDeviceIDs { engine.activate(new.controlDeviceIDs) }
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

    // MARK: - 学键

    func startLearning() {
        guard activeDevice != nil else {
            message = "先选一个控制设备"
            return
        }
        isLearning = true
        learned = nil
        engine.learnHandler = { [weak self] event in
            self?.isLearning = false
            self?.learned = event
        }
    }

    func cancelLearning() {
        isLearning = false
        engine.learnHandler = nil
    }

    func addBinding(button: ButtonID, label: String, gesture: GestureKind, action: Action) {
        update { $0.keyMap.set(KeyBinding(button: button, buttonLabel: label, gesture: gesture, action: action)) }
    }

    func removeBinding(_ id: UUID) {
        update { $0.keyMap.bindings.removeAll { $0.id == id } }
    }

    // MARK: - 权限

    func refreshPermissions() {
        var current: [Permission: Bool] = [:]
        for permission in Permission.allCases { current[permission] = permission.isGranted }
        guard current != permissions else { return }
        let gainedInput = current[.inputMonitoring] == true && permissions[.inputMonitoring] == false
        let gainedAccessibility = current[.accessibility] == true && permissions[.accessibility] == false
        permissions = current
        if gainedInput || gainedAccessibility {
            engine.activate(config.controlDeviceIDs)
        }
    }

    var missingPermissions: [Permission] {
        Permission.allCases.filter { permissions[$0] != true && ($0 != .microphone || config.voice.mode == .builtIn) }
    }

    // MARK: - 调试

    /// 不按键直接试一次转写（菜单里的「试一下」）：开始 3 秒后结束。
    func tryVoice() {
        voice.voiceBegin()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.voice.voiceEnd() }
    }
}
