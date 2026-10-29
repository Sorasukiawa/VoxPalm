import AppKit
import Foundation

/// 这次说话的附加要求。
public struct VoiceRequest: Equatable, Sendable {
    /// 说完、字贴进去后自动按回车发送
    public var sendReturn: Bool

    public init(sendReturn: Bool = false) {
        self.sendReturn = sendReturn
    }
}

/// 语音动作交给语音会话处理（VoxPalmVoice 实现）。
public protocol VoiceActionHandler: AnyObject {
    var isVoiceActive: Bool { get }
    /// 当前能否开始新一轮说话；转写期间不能抢占，待发回车可由新会话取消。
    var canStartVoice: Bool { get }
    /// 按下了「长按 = 按住说话」的键：先开麦预录，防止吞掉第一个字
    func voiceArm(_ request: VoiceRequest)
    /// 最后不是长按：丢掉预录。这个键没绑单击、双击时传长按门槛，界面提示「按得太短」；绑了就传 nil，安静地丢掉
    func voiceDisarm(tooShortFor threshold: Double?)
    /// 开始说话
    func voiceBegin(_ request: VoiceRequest)
    /// 说完了：停止并出字
    func voiceEnd()
    /// 设备断开或停止监听：释放输入法按键、丢掉内置录音，不自动贴字或发送。
    func voiceCancel()
}

public extension VoiceActionHandler {
    var canStartVoice: Bool { !isVoiceActive }
}

/// 免费版和 Pro 的差别由这里决定；Pro 包换成自己的实现。
public protocol FeatureGate {
    var editionName: String { get }
    var maxActiveControlDevices: Int { get }
    var maxKeyMaps: Int { get }
}

public struct FreeEdition: FeatureGate {
    public init() {}
    public var editionName: String { "免费版" }
    public var maxActiveControlDevices: Int { 1 }
    public var maxKeyMaps: Int { 1 }
}

/// 按键 → 手势 → 动作。全部在主线程跑。
public final class ButtonEngine {
    public let sources: [ControlSource]
    public var keyMap: KeyMap {
        didSet {
            if keyMap != oldValue { cancelAllInput(message: "按键映射已变更，本次说话已停止") }
        }
    }
    public var timing: GestureTiming {
        get { recognizer.timing }
        set { recognizer.timing = newValue }
    }
    public var gate: FeatureGate
    public weak var voice: VoiceActionHandler?
    public var textMethod: TextInserter.Method = .paste

    /// 原始按键（界面上显示「最近按键」用）
    public var onButtonEvent: ((ButtonEvent) -> Void)?
    public var onInputCancelled: ((String) -> Void)?
    /// 识别出的手势和执行的动作（界面、日志用）
    public var onGesture: ((ButtonEvent, RecognizedGesture, Action?) -> Void)?
    /// 动作执行的结果说明（失败原因、回车发没发），界面上显示
    public var onMessage: ((String) -> Void)?
    /// 动作做完到开始说话之间等多久：切对话后 App 要一点时间把光标放进输入框
    public var talkAfterDelay: Double = 0.4
    /// 设置了就进入「学键」模式：下一次按下被交给它，不执行动作
    public var learnHandler: ((ButtonEvent) -> Void)? {
        didSet {
            if oldValue == nil, learnHandler != nil { cancelAllInput(message: "已进入学键模式，本次说话已停止") }
        }
    }
    /// 设置了就进入「认设备」模式（引导里选设备那步）：除了选中的设备，所有 HID 设备和系统媒体键也在听，
    /// 任意一台按下都交给它，不执行动作、不拦键。不碰键盘按键（免得打字时乱认）和「正在播放」（会抢走别的播放器的命令）。
    public var identifyHandler: ((ButtonEvent) -> Void)? {
        didSet {
            guard (oldValue == nil) != (identifyHandler == nil) else { return }
            cancelAllInput(message: "设备识别模式已变更，本次说话已停止")
            applyActivation()
        }
    }

    public private(set) var activeDeviceIDs: Set<String> = []

    private let recognizer: GestureRecognizer
    private var armed: Set<String> = []
    private var talking: Set<String> = []
    /// 按一下开始的说话是哪个键开始的：再按一次这个键就结束，而不是再执行一遍它的动作
    private var voiceOwner: String?
    /// 松开以后仍可能在转写或等待回车；设备所有权要保留到交付完成后的下一次说话，或明确取消。
    private var deliveryOwner: String?
    /// 结束说话的那次按下，对应的松开也不要再交给手势识别
    private var swallowUntilUp: Set<String> = []
    private var cancellationEpoch: [String: UInt64] = [:]
    public init(sources: [ControlSource], keyMap: KeyMap = KeyMap(), gate: FeatureGate = FreeEdition(), scheduler: GestureScheduler = MainQueueScheduler()) {
        self.sources = sources
        self.keyMap = keyMap
        self.gate = gate
        recognizer = GestureRecognizer(scheduler: scheduler)
        recognizer.hasBinding = { [weak self] event, gesture in
            guard let self else { return false }
            // 报不出双击的设备：设了双击也不等，单击立刻生效
            if gesture == .double, !self.reportsDoubleTap(event.deviceID) { return false }
            return self.keyMap.hasBinding(event.button, gesture)
        }
        recognizer.onGesture = { [weak self] event, gesture in self?.handle(gesture, event: event) }
        for source in sources {
            source.onEvent = { [weak self] in self?.handle($0) }
            source.onInputCancelled = { [weak self] in self?.cancelInput(deviceID: $0) }
            source.isMapped = { [weak self] button in
                guard let self, self.learnHandler == nil, self.identifyHandler == nil else { return false }
                return self.keyMap.isMapped(button)
            }
        }
    }

    public func allDevices() -> [ControlDevice] { sources.flatMap { $0.devices() } }

    /// 启用这些控制设备。超过版本上限的部分忽略（免费版 1 台）。
    @discardableResult
    public func activate(_ deviceIDs: [String]) -> Set<String> {
        var seen = Set<String>()
        let allowed = Set(deviceIDs.filter { seen.insert($0).inserted }.prefix(max(0, gate.maxActiveControlDevices)))
        for id in activeDeviceIDs.subtracting(allowed) { cancelInput(deviceID: id) }
        activeDeviceIDs = allowed
        applyActivation()
        return allowed
    }

    public func cancelInput(deviceID: String) {
        cancelInput(deviceID: deviceID, message: "控制设备已断开或停用，本次说话已停止")
    }

    private func cancelInput(deviceID: String, message: String, cancelsVoice: Bool = true) {
        let prefix = deviceID + "|"
        cancellationEpoch[deviceID, default: 0] &+= 1
        recognizer.cancel(deviceID: deviceID)
        let ownedVoice = armed.contains { $0.hasPrefix(prefix) } || talking.contains { $0.hasPrefix(prefix) }
            || voiceOwner?.hasPrefix(prefix) == true || deliveryOwner?.hasPrefix(prefix) == true
        armed = armed.filter { !$0.hasPrefix(prefix) }
        talking = talking.filter { !$0.hasPrefix(prefix) }
        swallowUntilUp = swallowUntilUp.filter { !$0.hasPrefix(prefix) }
        if voiceOwner?.hasPrefix(prefix) == true { voiceOwner = nil }
        if deliveryOwner?.hasPrefix(prefix) == true { deliveryOwner = nil }
        if ownedVoice, cancelsVoice {
            voice?.voiceCancel()
            onMessage?(message)
        }
        onInputCancelled?(deviceID)
    }

    /// 切模式、改映射或退出时，手势、预录和延迟动作必须一起作废。
    private func cancelAllInput(message: String) {
        let ownedVoice = !armed.isEmpty || !talking.isEmpty || voiceOwner != nil || deliveryOwner != nil
        for id in activeDeviceIDs { cancelInput(deviceID: id, message: message, cancelsVoice: false) }
        recognizer.reset()
        armed.removeAll()
        talking.removeAll()
        swallowUntilUp.removeAll()
        voiceOwner = nil
        deliveryOwner = nil
        // 也要覆盖从界面开始、没有设备所有权的语音；不要在逐设备循环里重复取消。
        voice?.voiceCancel()
        if ownedVoice { onMessage?(message) }
    }

    /// 认设备时额外听的设备
    public static func identifiableDeviceIDs(_ devices: [ControlDevice]) -> Set<String> {
        Set(devices.filter { $0.sourceID == "hid" || $0.id.hasPrefix("hid:") }.map(\.id)).union([SystemKeysControlSource.mediaDeviceID])
    }

    private func applyActivation() {
        var ids = activeDeviceIDs
        if identifyHandler != nil { ids.formUnion(Self.identifiableDeviceIDs(allDevices())) }
        for source in sources {
            source.isIdentifying = identifyHandler != nil
            source.activate(ids)
        }
    }

    /// App 退出前调用：等每个来源收尾（最多 `timeout` 秒），再调 completion。
    public func shutdown(timeout: Double = 10, completion: @escaping () -> Void) {
        cancelAllInput(message: "掌声正在退出，本次说话已停止")
        activeDeviceIDs.removeAll()
        let group = DispatchGroup()
        for source in sources {
            group.enter()
            source.shutdown { DispatchQueue.main.async { group.leave() } }
        }
        var finished = false
        let finish = {
            guard !finished else { return }
            finished = true
            completion()
        }
        group.notify(queue: .main, execute: finish)
        DispatchQueue.main.asyncAfter(deadline: .now() + GestureTiming.safeInterval(timeout, fallback: 10, allowsZero: true), execute: finish)
    }

    public func diagram(for device: ControlDevice) -> DeviceDiagram? {
        sources.first { $0.sourceID == device.sourceID }?.diagram(for: device)
    }

    public func status(of deviceID: String) -> String? {
        source(of: deviceID)?.status
    }

    /// 设备现在用不了的原因（适配模块报的，比如接管按键失败）；nil 表示正常
    public func problem(of deviceID: String) -> String? {
        source(of: deviceID)?.problem(for: deviceID)
    }

    public func retry(_ deviceID: String) {
        source(of: deviceID)?.retry(deviceID)
    }

    /// 这台设备能不能做双击（适配模块说了算，默认能）
    public func reportsDoubleTap(_ deviceID: String) -> Bool {
        sources.allSatisfy { $0.reportsDoubleTap(deviceID) }
    }

    /// 现在启用的控制设备接管按键时会被静音的收音设备（音频设备 UID）
    public func mutedInputs() -> Set<String> {
        var result = Set<String>()
        for id in activeDeviceIDs {
            for source in sources { result.formUnion(source.mutedInputs(for: id)) }
        }
        return result
    }

    private func source(of deviceID: String) -> ControlSource? {
        sources.first { source in source.devices().contains { $0.id == deviceID } }
    }

    /// 测试和调试入口：直接喂一个按键事件。
    public func handle(_ event: ButtonEvent) {
        if let identify = identifyHandler {
            if event.phase != .up { identify(event) }
            return
        }
        guard activeDeviceIDs.contains(event.deviceID) else { return }
        onButtonEvent?(event)
        if let learn = learnHandler {
            if event.phase != .up {
                learnHandler = nil
                learn(event)
            }
            return
        }
        let id = key(event)
        if swallowUntilUp.contains(id) {
            if event.phase == .up { swallowUntilUp.remove(id) }
            return
        }
        // 正在说的话是这个键开始的：这次按下就是「说完了」。
        if event.phase != .up, voiceOwner == id, voice?.isVoiceActive == true {
            voiceOwner = nil
            if event.phase == .down { swallowUntilUp.insert(id) }
            voice?.voiceEnd()
            onGesture?(event, .single, .toggleDictation)
            return
        }
        recognizer.handle(event)
    }

    private func key(_ event: ButtonEvent) -> String { "\(event.deviceID)|\(event.button.rawValue)" }

    private func handle(_ gesture: RecognizedGesture, event: ButtonEvent) {
        let id = key(event)
        var binding: KeyBinding?
        switch gesture {
        case .pressBegan:
            if let long = keyMap.binding(for: event.button, gesture: .long), long.action == .pushToTalk,
               armed.isEmpty, talking.isEmpty, let voice, voice.canStartVoice {
                armed.insert(id)
                deliveryOwner = id
                voice.voiceArm(VoiceRequest(sendReturn: long.sendAfterTalk == true))
            }
        case .pressEnded:
            if armed.contains(id), !talking.contains(id) {
                armed.remove(id)
                if deliveryOwner == id { deliveryOwner = nil }
                let hasTap = keyMap.hasBinding(event.button, .single) || keyMap.hasBinding(event.button, .double)
                voice?.voiceDisarm(tooShortFor: hasTap ? nil : timing.longPressThreshold)
            }
        case .single:
            binding = keyMap.binding(for: event.button, gesture: .single)
        case .double:
            binding = keyMap.binding(for: event.button, gesture: .double)
        case .longBegan:
            binding = keyMap.binding(for: event.button, gesture: .long)
            if let binding, binding.action == .pushToTalk {
                // 只有成功认领预录的按键能开始和结束这次说话，其他按住的键不能抢走会话。
                guard armed.remove(id) != nil else { return }
                talking.insert(id)
                voice?.voiceBegin(VoiceRequest(sendReturn: binding.sendAfterTalk == true))
                onGesture?(event, gesture, .pushToTalk)
                return
            }
        case .longEnded:
            if talking.remove(id) != nil {
                voice?.voiceEnd()
                onGesture?(event, gesture, .pushToTalk)
                return
            }
        }
        onGesture?(event, gesture, binding?.action)
        if let binding { run(binding, owner: id) }
    }

    /// 执行一条映射：先做动作，要的话接着开始说话（这个键再按一次结束）。
    private func run(_ binding: KeyBinding, owner: String) {
        let request = VoiceRequest(sendReturn: binding.sendAfterTalk == true)
        let deviceID = activeDeviceIDs.first { owner.hasPrefix($0 + "|") }
        let epoch = deviceID.map { cancellationEpoch[$0, default: 0] }
        if binding.action.isVoice {
            guard let voice else { return }
            if voice.isVoiceActive {
                voiceOwner = nil
                voice.voiceEnd()
            } else if voice.canStartVoice {
                voiceOwner = owner
                deliveryOwner = owner
                voice.voiceBegin(request)
            }
            return
        }
        Task { @MainActor in
            guard let deviceID, self.activeDeviceIDs.contains(deviceID),
                  self.cancellationEpoch[deviceID, default: 0] == epoch else { return }
            let ok = await perform(binding.action)
            guard ok, binding.talkAfter == true, let voice = self.voice, voice.canStartVoice else { return }
            let delay = GestureTiming.safeInterval(talkAfterDelay, fallback: 0.4, allowsZero: true)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard self.activeDeviceIDs.contains(deviceID), voice.canStartVoice,
                  self.cancellationEpoch[deviceID, default: 0] == epoch else { return }
            self.voiceOwner = owner
            self.deliveryOwner = owner
            voice.voiceBegin(request)
        }
    }

    /// 执行一个动作，返回有没有做成（失败原因通过 onMessage 报告）。
    @discardableResult
    @MainActor
    public func perform(_ action: Action) async -> Bool {
        switch action {
        case .none:
            return true
        case .pushToTalk, .toggleDictation:
            toggleVoice()
        case let .shortcut(combo):
            KeyPoster.post(combo)
        case let .text(text):
            if case let .copied(block) = TextDelivery.insert(text, method: textMethod, since: nil).result {
                onMessage?("字放进了剪贴板：\(block.pasteMessage)")
            }
        case let .mediaKey(key):
            KeyPoster.postMediaKey(key)
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case let .menuCommand(command):
            return report(await AppCommander.run(command))
        case let .switchChat(direction):
            return report(await AppCommander.switchChat(direction))
        case .sendReturn:
            onMessage?(TextDelivery.sendReturn())
        }
        return true
    }

    private func report(_ outcome: AppCommander.Outcome) -> Bool {
        if case let .failed(message) = outcome {
            onMessage?(message)
            return false
        }
        return true
    }

    private func toggleVoice() {
        guard let voice else { return }
        if voice.isVoiceActive { voice.voiceEnd() }
        else if voice.canStartVoice {
            voiceOwner = nil
            deliveryOwner = nil
            voice.voiceBegin(VoiceRequest())
        }
    }
}
