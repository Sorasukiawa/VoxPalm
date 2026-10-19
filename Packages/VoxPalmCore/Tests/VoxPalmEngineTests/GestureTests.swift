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
    func voiceArm() { log.append("arm") }
    func voiceDisarm() { log.append("disarm") }
    func voiceBegin() { log.append("begin"); isVoiceActive = true }
    func voiceEnd() { log.append("end"); isVoiceActive = false }
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
