import Foundation
import Testing
@testable import VoxPalmEngine

/// 手动拨时间的定时器。
final class ManualScheduler: GestureScheduler {
    private final class Job { let at: Double; let work: () -> Void; var cancelled = false; init(at: Double, work: @escaping () -> Void) { self.at = at; self.work = work } }
    private var jobs: [Job] = []
    private(set) var now = 0.0

    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> AnyObject {
        let job = Job(at: now + seconds, work: work)
        jobs.append(job)
        return job
    }

    func cancel(_ token: AnyObject) { (token as? Job)?.cancelled = true }

    func advance(to time: Double) {
        while let job = jobs.filter({ !$0.cancelled && $0.at <= time }).min(by: { $0.at < $1.at }) {
            job.cancelled = true
            now = job.at
            job.work()
        }
        now = time
    }
}

final class FakeSource: ControlSource {
    let sourceID = "fake"
    var onEvent: ((ButtonEvent) -> Void)?
    var onDevicesChanged: (() -> Void)?
    var isMapped: ((ButtonID) -> Bool)?
    var status = "测试"
    func devices() -> [ControlDevice] { [ControlDevice(id: "fake:1", sourceID: sourceID, name: "测试遥控器", detail: "", reportsRelease: true)] }
    func activate(_ deviceIDs: Set<String>) {}
}

final class FakeVoice: VoiceActionHandler {
    var log: [String] = []
    var isVoiceActive = false
    var lastRequest: VoiceRequest?
    func voiceArm(_ request: VoiceRequest) { log.append("arm"); lastRequest = request }
    var shortThreshold: Double?
    func voiceDisarm(tooShortFor threshold: Double?) { log.append("disarm"); shortThreshold = threshold }
    func voiceBegin(_ request: VoiceRequest) { log.append("begin"); isVoiceActive = true; lastRequest = request }
    func voiceEnd() { log.append("end"); isVoiceActive = false }
    func voiceCancel() { log.append("cancel"); isVoiceActive = false }
}

private let button = ButtonID("hid:0x0C:0xCD")

private func event(_ phase: ButtonEvent.Phase, _ t: Double) -> ButtonEvent {
    ButtonEvent(deviceID: "fake:1", button: button, label: "Play/Pause", phase: phase, time: t)
}

private func recognizer(bindings: Set<GestureKind>) -> (GestureRecognizer, ManualScheduler, () -> [RecognizedGesture]) {
    let scheduler = ManualScheduler()
    let recognizer = GestureRecognizer(scheduler: scheduler)
    recognizer.hasBinding = { _, gesture in bindings.contains(gesture) }
    var out: [RecognizedGesture] = []
    recognizer.onGesture = { _, gesture in out.append(gesture) }
    return (recognizer, scheduler, { out.filter { $0 != .pressBegan && $0 != .pressEnded } })
}

@Test func 没绑双击时单击立刻触发() {
    let (r, s, out) = recognizer(bindings: [.single])
    r.handle(event(.down, 0)); s.advance(to: 0.1); r.handle(event(.up, 0.1))
    #expect(out() == [.single])
}

@Test func 绑了双击时单击要等窗口过去() {
    let (r, s, out) = recognizer(bindings: [.single, .double])
    r.handle(event(.down, 0)); s.advance(to: 0.1); r.handle(event(.up, 0.1))
    #expect(out().isEmpty)
    s.advance(to: 0.5)
    #expect(out() == [.single])
}

@Test func 双击() {
    let (r, s, out) = recognizer(bindings: [.single, .double])
    r.handle(event(.down, 0)); s.advance(to: 0.08); r.handle(event(.up, 0.08))
    s.advance(to: 0.2); r.handle(event(.down, 0.2)); s.advance(to: 0.28); r.handle(event(.up, 0.28))
    s.advance(to: 1)
    #expect(out() == [.double])
}

@Test func 长按开始和结束() {
    let (r, s, out) = recognizer(bindings: [.single, .long])
    r.handle(event(.down, 0)); s.advance(to: 1.2)
    #expect(out() == [.longBegan])
    r.handle(event(.up, 1.2))
    #expect(out() == [.longBegan, .longEnded])
}

@Test func 没绑长按时按久了也算单击() {
    let (r, s, out) = recognizer(bindings: [.single])
    r.handle(event(.down, 0)); s.advance(to: 1.5); r.handle(event(.up, 1.5))
    #expect(out() == [.single])
}

@Test func 只有触发的键也能双击() {
    let (r, s, out) = recognizer(bindings: [.single, .double])
    r.handle(event(.trigger, 0)); s.advance(to: 0.15); r.handle(event(.trigger, 0.15))
    #expect(out() == [.double])
    r.handle(event(.trigger, 1)); s.advance(to: 2)
    #expect(out() == [.double, .single])
}

@Test func 按住说话先预录再开始() {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: scheduler)
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "Play/Pause", gesture: .long, action: .pushToTalk))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    engine.handle(event(.down, 0))
    #expect(voice.log == ["arm"])
    scheduler.advance(to: 2)
    #expect(voice.log == ["arm", "begin"])
    engine.handle(event(.up, 2))
    #expect(voice.log == ["arm", "begin", "end"])
}

@Test func 按住说话的键短按会丢掉预录() {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: scheduler)
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "Play/Pause", gesture: .long, action: .pushToTalk))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    engine.handle(event(.down, 0)); scheduler.advance(to: 0.1); engine.handle(event(.up, 0.1))
    #expect(voice.log == ["arm", "disarm"])
    // 这个键没绑单击、双击：告诉界面是「按得太短」
    #expect(voice.shortThreshold == engine.timing.longPressThreshold)
}

@Test func 绑了单击的键短按不算按得太短() {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: scheduler)
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "OK", gesture: .long, action: .pushToTalk))
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "OK", gesture: .single, action: .toggleDictation))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    engine.handle(event(.down, 0)); scheduler.advance(to: 0.1); engine.handle(event(.up, 0.1))
    #expect(voice.log == ["arm", "disarm", "begin"])
    #expect(voice.shortThreshold == nil)
}

@Test func 免费版只能启用一台控制设备() {
    let engine = ButtonEngine(sources: [FakeSource()])
    #expect(engine.activate(["fake:1", "fake:2"]) == ["fake:1"])
}

@Test func 学键模式拿到按键不执行动作() {
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: ManualScheduler())
    engine.activate(["fake:1"])
    var learned: ButtonID?
    engine.learnHandler = { learned = $0.button }
    engine.handle(event(.down, 0))
    #expect(learned == button)
    #expect(engine.learnHandler == nil)
}

@Test func 键位方案同键同手势只留一条() {
    var map = KeyMap()
    map.set(KeyBinding(button: button, buttonLabel: "", gesture: .single, action: .mediaKey(.playPause)))
    map.set(KeyBinding(button: button, buttonLabel: "", gesture: .single, action: .shortcut(.returnKey)))
    #expect(map.bindings.count == 1)
    #expect(map.action(for: button, gesture: .single) == .shortcut(.returnKey))
}

/// 等引擎后台任务做完：云端机器卡顿时固定睡 0.1 秒不够，按条件等，最多 5 秒。
@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 10_000_000) }
}

@Test @MainActor func 切完对话直接说话再按同一个键结束() async throws {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: scheduler)
    engine.talkAfterDelay = 0
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "下", gesture: .single, action: .none, talkAfter: true, sendAfterTalk: true))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    engine.handle(event(.down, 0)); engine.handle(event(.up, 0.1))
    try await waitUntil { !voice.log.isEmpty }
    #expect(voice.log == ["begin"])
    #expect(voice.lastRequest?.sendReturn == true)
    // 再按一次同一个键：结束说话，不会再执行一次动作、也不会再开始说话。
    engine.handle(event(.down, 5)); engine.handle(event(.up, 5.1))
    try await waitUntil { voice.log.count >= 2 }
    // 再多等一会儿，确认后面没有多出一次开始说话
    try await Task.sleep(nanoseconds: 100_000_000)
    #expect(voice.log == ["begin", "end"])
}

@Test func 按住说话带回车发送的要求() {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], scheduler: scheduler)
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "OK", gesture: .long, action: .pushToTalk, sendAfterTalk: true))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    engine.handle(event(.down, 0))
    #expect(voice.lastRequest?.sendReturn == true)
    scheduler.advance(to: 1)
    engine.handle(event(.up, 1))
    #expect(voice.log == ["arm", "begin", "end"])
}

@Test func 映射说明() {
    let binding = KeyBinding(button: button, buttonLabel: "", gesture: .single, action: .switchChat(.next), talkAfter: true, sendAfterTalk: true)
    #expect(binding.summary == "下一个对话 → 说话 → 发送")
    #expect(KeyBinding(button: button, buttonLabel: "", gesture: .long, action: .pushToTalk, sendAfterTalk: true).summary == "按住说话 → 发送")
}

@Test func 旧配置没有新字段也能读() throws {
    let json = #"{"id":"11111111-1111-1111-1111-111111111111","button":"key:79","buttonLabel":"F18","gesture":"long","action":{"pushToTalk":{}}}"#
    let binding = try JSONDecoder().decode(KeyBinding.self, from: Data(json.utf8))
    #expect(binding.action == .pushToTalk)
    #expect(binding.talkAfter == nil)
}

@Test func 新动作能存能读() throws {
    let actions: [Action] = [.switchChat(.previous), .sendReturn, .menuCommand(AIToolProfile.claude.open), .menuCommand(AIToolProfile.codex.nextChat)]
    for action in actions {
        let data = try JSONEncoder().encode(action)
        #expect(try JSONDecoder().decode(Action.self, from: data) == action)
    }
}

@Test func 示意图的按键都在设备范围内且不重名() {
    for diagram in DeviceDiagram.choices + [DeviceDiagram.mediaKeys] where diagram.id != "generic" {
        #expect(Set(diagram.spots.map(\.id)).count == diagram.spots.count, "\(diagram.id) 有重名的按键")
        for item in diagram.spots.map(\.box) + diagram.parts.map(\.box) {
            #expect(item.x >= -0.01 && item.y >= -0.01 && item.x + item.w <= diagram.width + 0.01 && item.y + item.h <= diagram.height + 0.01,
                    "\(diagram.id) 有部件超出画布")
        }
    }
    #expect(DeviceDiagram.mediaKeys.spots.allSatisfy { $0.button != nil })
    let generic = DeviceDiagram.generic(buttons: [(ButtonID("key:1"), "A"), (ButtonID("key:2"), "B")])
    #expect(generic.spots.map(\.button) == [ButtonID("key:1"), ButtonID("key:2")])
}

@Test func 按设备标识认出小米遥控器() {
    let device = ControlDevice(id: "hid:x", sourceID: "hid", name: "小米蓝牙遥控器", detail: "Bluetooth Low Energy · 0x2717:0x32B8 · 媒体键（Consumer Control）、键盘", reportsRelease: true)
    #expect(DeviceDiagram.guess(for: device).id == "xiaomi-remote-2")
}

/// 记下被启用了哪些设备的假 HID 来源。
final class RecordingHIDSource: ControlSource {
    let sourceID = "hid"
    var onEvent: ((ButtonEvent) -> Void)?
    var onDevicesChanged: (() -> Void)?
    var isMapped: ((ButtonID) -> Bool)?
    var status = "测试"
    private(set) var active: Set<String> = []
    func devices() -> [ControlDevice] {
        ["hid:1", "hid:2"].map { ControlDevice(id: $0, sourceID: sourceID, name: $0, detail: "", reportsRelease: true) }
    }
    func activate(_ deviceIDs: Set<String>) { active = deviceIDs }
}

@Test func 认设备模式听所有设备也不执行动作() {
    let source = RecordingHIDSource()
    let engine = ButtonEngine(sources: [source], scheduler: ManualScheduler())
    let voice = FakeVoice()
    engine.keyMap.set(KeyBinding(button: button, buttonLabel: "OK", gesture: .long, action: .pushToTalk))
    engine.voice = voice
    engine.activate(["hid:1"])
    #expect(source.active == ["hid:1"])
    var heard: [String] = []
    engine.identifyHandler = { heard.append($0.deviceID) }
    #expect(source.active == ["hid:1", "hid:2", SystemKeysControlSource.mediaDeviceID])
    #expect(source.isMapped?(button) == false)
    engine.handle(ButtonEvent(deviceID: "hid:2", button: button, label: "OK", phase: .down, time: 0))
    engine.handle(ButtonEvent(deviceID: "hid:2", button: button, label: "OK", phase: .up, time: 0.1))
    engine.handle(ButtonEvent(deviceID: "hid:1", button: button, label: "OK", phase: .down, time: 1))
    #expect(heard == ["hid:2", "hid:1"])
    #expect(voice.log == ["cancel"])
    engine.identifyHandler = nil
    #expect(source.active == ["hid:1"])
}

@Test func 每种外形都有建议的说话键() {
    #expect(DeviceDiagram.xiaomiRemote2.recommendedTalkSpot?.id == "ok")
    #expect(DeviceDiagram.siriRemote.recommendedTalkSpot?.id == "ok")
    #expect(DeviceDiagram.micTransmitter.recommendedTalkSpot?.id == "record")
    #expect(DeviceDiagram.footPedal.recommendedTalkSpot?.id == "middle")
    #expect(DeviceDiagram.presenter.recommendedTalkSpot?.id == "laser")
    #expect(DeviceDiagram.mediaKeys.recommendedTalkSpot?.id == "playPause")
}

@Test func 键盘按键的名字() {
    // F18 按出来是私用区字符 U+F715，看不见，要用固定的名字
    #expect(KeyCodeNames.label(keyCode: 79, characters: "\u{F715}") == "按键 F18（79）")
    #expect(KeyCodeNames.label(keyCode: 0, characters: "a") == "按键 a（0）")
    #expect(KeyCodeNames.label(keyCode: 76, characters: "\u{3}") == "按键 76")
    #expect(KeyCodeNames.label(keyCode: 0, characters: nil) == "按键 0")
}

/// 接管后报不出双击的设备（一次性触发），会让自己的麦静音
final class SingleTapSource: ControlSource {
    let sourceID = "single-tap"
    var onEvent: ((ButtonEvent) -> Void)?
    var onDevicesChanged: (() -> Void)?
    var isMapped: ((ButtonID) -> Bool)?
    var status = "测试"
    private var active: Set<String> = []
    func devices() -> [ControlDevice] { [ControlDevice(id: "mic:1", sourceID: sourceID, name: "测试无线麦", detail: "", reportsRelease: false)] }
    func activate(_ deviceIDs: Set<String>) { active = deviceIDs.filter { $0.hasPrefix("mic:") } }
    func reportsDoubleTap(_ deviceID: String) -> Bool { !deviceID.hasPrefix("mic:") }
    func mutedInputs(for deviceID: String) -> Set<String> { active.contains(deviceID) ? ["MIC-UID"] : [] }
}

@Test func 报不出双击的设备设了双击也不等() {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource(), SingleTapSource()], scheduler: scheduler)
    let key = ButtonID("mic:key:2")
    engine.keyMap.set(KeyBinding(button: key, buttonLabel: "录制键", gesture: .single, action: .toggleDictation))
    engine.keyMap.set(KeyBinding(button: key, buttonLabel: "录制键", gesture: .double, action: .sendReturn))
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["mic:1"])
    #expect(!engine.reportsDoubleTap("mic:1"))
    #expect(engine.reportsDoubleTap("fake:1"))
    engine.handle(ButtonEvent(deviceID: "mic:1", button: key, label: "录制键", phase: .trigger, time: 0))
    // 不等双击窗口，单击马上生效
    #expect(voice.log == ["begin"])
}

@Test func 启用的控制设备报出会静音的麦() {
    let engine = ButtonEngine(sources: [FakeSource(), SingleTapSource()])
    #expect(engine.mutedInputs().isEmpty)
    engine.activate(["mic:1"])
    #expect(engine.mutedInputs() == ["MIC-UID"])
    engine.activate(["fake:1"])
    #expect(engine.mutedInputs().isEmpty)
}
