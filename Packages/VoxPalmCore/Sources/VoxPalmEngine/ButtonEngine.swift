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
    /// 按下了「长按 = 按住说话」的键：先开麦预录，防止吞掉第一个字
    func voiceArm(_ request: VoiceRequest)
    /// 最后不是长按：丢掉预录。这个键没绑单击、双击时传长按门槛，界面提示「按得太短」；绑了就传 nil，安静地丢掉
    func voiceDisarm(tooShortFor threshold: Double?)
    /// 开始说话
    func voiceBegin(_ request: VoiceRequest)
    /// 说完了：停止并出字
    func voiceEnd()
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
        didSet { recognizer.reset() }
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
    /// 识别出的手势和执行的动作（界面、日志用）
    public var onGesture: ((ButtonEvent, RecognizedGesture, Action?) -> Void)?
    /// 动作执行的结果说明（失败原因、回车发没发），界面上显示
    public var onMessage: ((String) -> Void)?
    /// 动作做完到开始说话之间等多久：切对话后 App 要一点时间把光标放进输入框
    public var talkAfterDelay: Double = 0.4
    /// 设置了就进入「学键」模式：下一次按下被交给它，不执行动作
    public var learnHandler: ((ButtonEvent) -> Void)?

    public private(set) var activeDeviceIDs: Set<String> = []

    private let recognizer: GestureRecognizer
    private var armed: Set<String> = []
    private var talking: Set<String> = []
    /// 按一下开始的说话是哪个键开始的：再按一次这个键就结束，而不是再执行一遍它的动作
    private var voiceOwner: String?
    /// 结束说话的那次按下，对应的松开也不要再交给手势识别
    private var swallowUntilUp: Set<String> = []
    public init(sources: [ControlSource], keyMap: KeyMap = KeyMap(), gate: FeatureGate = FreeEdition(), scheduler: GestureScheduler = MainQueueScheduler()) {
        self.sources = sources
        self.keyMap = keyMap
        self.gate = gate
        recognizer = GestureRecognizer(scheduler: scheduler)
        recognizer.hasBinding = { [weak self] button, gesture in self?.keyMap.hasBinding(button, gesture) ?? false }
        recognizer.onGesture = { [weak self] event, gesture in self?.handle(gesture, event: event) }
        for source in sources {
            source.onEvent = { [weak self] in self?.handle($0) }
            source.isMapped = { [weak self] button in
                guard let self, self.learnHandler == nil else { return false }
                return self.keyMap.isMapped(button)
            }
        }
    }

    public func allDevices() -> [ControlDevice] { sources.flatMap { $0.devices() } }

    /// 启用这些控制设备。超过版本上限的部分忽略（免费版 1 台）。
    @discardableResult
    public func activate(_ deviceIDs: [String]) -> Set<String> {
        let allowed = Set(deviceIDs.prefix(gate.maxActiveControlDevices))
        activeDeviceIDs = allowed
        recognizer.reset()
        for source in sources { source.activate(allowed) }
        return allowed
    }

    /// App 退出前调用：等每个来源收尾（最多 `timeout` 秒），再调 completion。
    public func shutdown(timeout: Double = 10, completion: @escaping () -> Void) {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: finish)
    }

    public func diagram(for device: ControlDevice) -> DeviceDiagram? {
        sources.first { $0.sourceID == device.sourceID }?.diagram(for: device)
    }

    public func status(of deviceID: String) -> String? {
        sources.first { source in source.devices().contains { $0.id == deviceID } }?.status
    }

    /// 测试和调试入口：直接喂一个按键事件。
    public func handle(_ event: ButtonEvent) {
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
            if let long = keyMap.binding(for: event.button, gesture: .long), long.action == .pushToTalk, voice?.isVoiceActive != true {
                armed.insert(id)
                voice?.voiceArm(VoiceRequest(sendReturn: long.sendAfterTalk == true))
            }
        case .pressEnded:
            if armed.contains(id), !talking.contains(id) {
                armed.remove(id)
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
                talking.insert(id)
                armed.remove(id)
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
        if binding.action.isVoice {
            if voice?.isVoiceActive == true {
                voiceOwner = nil
                voice?.voiceEnd()
            } else {
                voiceOwner = owner
                voice?.voiceBegin(request)
            }
            return
        }
        Task { @MainActor in
            let ok = await perform(binding.action)
            guard ok, binding.talkAfter == true, let voice = self.voice, !voice.isVoiceActive else { return }
            try? await Task.sleep(nanoseconds: UInt64(talkAfterDelay * 1_000_000_000))
            self.voiceOwner = owner
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
            TextInserter.insert(text, method: textMethod)
        case let .mediaKey(key):
            KeyPoster.postMediaKey(key)
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration(), completionHandler: nil)
        case let .menuCommand(command):
            return report(await AppCommander.run(command))
        case let .switchChat(direction):
            return report(await AppCommander.switchChat(direction))
        case .sendReturn:
            onMessage?(FocusedField.sendReturn())
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
        if voice.isVoiceActive { voice.voiceEnd() } else { voice.voiceBegin(VoiceRequest()) }
    }
}
