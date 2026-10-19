import AppKit
import Foundation

/// 语音动作交给语音会话处理（VoxPalmVoice 实现）。
public protocol VoiceActionHandler: AnyObject {
    var isVoiceActive: Bool { get }
    /// 按下了「长按 = 按住说话」的键：先开麦预录，防止吞掉第一个字
    func voiceArm()
    /// 最后不是长按（是单击、双击）：丢掉预录
    func voiceDisarm()
    /// 开始说话
    func voiceBegin()
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
    /// 设置了就进入「学键」模式：下一次按下被交给它，不执行动作
    public var learnHandler: ((ButtonEvent) -> Void)?

    public private(set) var activeDeviceIDs: Set<String> = []

    private let recognizer: GestureRecognizer
    private var armed: Set<String> = []
    private var talking: Set<String> = []

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
        recognizer.handle(event)
    }

    private func key(_ event: ButtonEvent) -> String { "\(event.deviceID)|\(event.button.rawValue)" }

    private func handle(_ gesture: RecognizedGesture, event: ButtonEvent) {
        let id = key(event)
        var action: Action?
        switch gesture {
        case .pressBegan:
            if keyMap.action(for: event.button, gesture: .long) == .pushToTalk, voice?.isVoiceActive != true {
                armed.insert(id)
                voice?.voiceArm()
            }
        case .pressEnded:
            if armed.contains(id), !talking.contains(id) {
                armed.remove(id)
                voice?.voiceDisarm()
            }
        case .single:
            action = keyMap.action(for: event.button, gesture: .single)
        case .double:
            action = keyMap.action(for: event.button, gesture: .double)
        case .longBegan:
            action = keyMap.action(for: event.button, gesture: .long)
            if action == .pushToTalk {
                talking.insert(id)
                armed.remove(id)
                voice?.voiceBegin()
                onGesture?(event, gesture, action)
                return
            }
        case .longEnded:
            if talking.remove(id) != nil {
                voice?.voiceEnd()
                onGesture?(event, gesture, .pushToTalk)
                return
            }
        }
        onGesture?(event, gesture, action)
        if let action { perform(action) }
    }

    public func perform(_ action: Action) {
        switch action {
        case .none:
            break
        case .pushToTalk, .toggleDictation:
            // 「按住说话」的按住和松手在 handle(_:event:) 里处理；走到这里说明它绑在了单击或双击上，当成「按一下开始 / 结束」。
            toggleVoice()
        case let .shortcut(combo):
            KeyPoster.post(combo)
        case let .text(text):
            Task { @MainActor in TextInserter.insert(text, method: textMethod) }
        case let .mediaKey(key):
            KeyPoster.postMediaKey(key)
        case let .openApp(path):
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: NSWorkspace.OpenConfiguration())
        }
    }

    private func toggleVoice() {
        guard let voice else { return }
        if voice.isVoiceActive { voice.voiceEnd() } else { voice.voiceBegin() }
    }
}
