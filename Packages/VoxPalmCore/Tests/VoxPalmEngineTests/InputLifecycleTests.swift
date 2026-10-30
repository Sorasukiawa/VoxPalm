import Foundation
import Testing
@testable import VoxPalmEngine

private let talkButton = ButtonID("test:talk")
private let delayedTalkButton = ButtonID("test:delayed-talk")

private func makeEngine() -> (ButtonEngine, FakeVoice, ManualScheduler) {
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], keyMap: KeyMap(bindings: [
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: .long, action: .pushToTalk),
    ]), scheduler: scheduler)
    let voice = FakeVoice()
    engine.voice = voice
    engine.activate(["fake:1"])
    return (engine, voice, scheduler)
}

private func input(_ engine: ButtonEngine, _ phase: ButtonEvent.Phase, button: ButtonID = talkButton, deviceID: String = "fake:1") {
    engine.handle(ButtonEvent(deviceID: deviceID, button: button, label: "测试按键", phase: phase, time: 0))
}

@Test func 更换映射取消预录和按住说话() {
    for alreadyTalking in [false, true] {
        let (engine, voice, scheduler) = makeEngine()
        input(engine, .down)
        if alreadyTalking { scheduler.advance(to: 1) }
        engine.keyMap = KeyMap()
        input(engine, .up)
        scheduler.advance(to: 2)
        #expect(voice.log == (alreadyTalking ? ["arm", "begin", "cancel"] : ["arm", "cancel"]))
        #expect(!voice.isVoiceActive)
    }
}

@Test func 重复激活同一设备不吞掉长按松开() {
    let (engine, voice, scheduler) = makeEngine()
    input(engine, .down)
    scheduler.advance(to: 1)
    engine.activate(["fake:1"])
    input(engine, .up)
    #expect(voice.log == ["arm", "begin", "end"])
}

@Test func 进入学键或认设备模式会取消原有长按() {
    for identify in [false, true] {
        let (engine, voice, scheduler) = makeEngine()
        input(engine, .down)
        if identify { engine.identifyHandler = { _ in } }
        else { engine.learnHandler = { _ in } }
        scheduler.advance(to: 2)
        input(engine, .up)
        #expect(voice.log == ["arm", "cancel"])
    }
}

@Test func 进入学键模式不会执行等待中的单击() {
    let (engine, voice, scheduler) = makeEngine()
    engine.keyMap = KeyMap(bindings: [
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: .single, action: .toggleDictation),
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: .double, action: .toggleDictation),
    ])
    voice.log.removeAll()
    input(engine, .down); input(engine, .up)
    engine.learnHandler = { _ in }
    scheduler.advance(to: 2)
    #expect(voice.log == ["cancel"])
}

@Test func 另一个长按键不能接管已有说话再提前结束() {
    let (engine, voice, scheduler) = makeEngine()
    let other = ButtonID("test:other")
    engine.keyMap.set(KeyBinding(button: other, buttonLabel: "另一个键", gesture: .long, action: .pushToTalk, sendAfterTalk: true))
    voice.log.removeAll()
    input(engine, .down)
    scheduler.advance(to: 1)
    input(engine, .down, button: other)
    scheduler.advance(to: 2)
    input(engine, .up, button: other)
    #expect(voice.log == ["arm", "begin"])
    #expect(voice.lastRequest?.sendReturn == false)
    input(engine, .up)
    #expect(voice.log == ["arm", "begin", "end"])
}

@Test @MainActor func 退出时取消活动说话且不依赖来源通知() async {
    let (engine, voice, scheduler) = makeEngine()
    input(engine, .down)
    scheduler.advance(to: 1)
    await withCheckedContinuation { continuation in
        engine.shutdown { continuation.resume() }
    }
    #expect(voice.log == ["arm", "begin", "cancel"])
    #expect(engine.activeDeviceIDs.isEmpty)
}

@Test @MainActor func 修改映射后不再执行之前排队的开始说话() async throws {
    final class QueuedVoice: VoiceActionHandler {
        var isVoiceActive = false
        var checks = 0
        var log: [String] = []
        var atReadyCheck: ((Int) -> Void)?
        var canStartVoice: Bool { checks += 1; atReadyCheck?(checks); return true }
        func voiceArm(_ request: VoiceRequest) {}
        func voiceDisarm(tooShortFor threshold: Double?) {}
        func voiceBegin(_ request: VoiceRequest) { log.append("begin") }
        func voiceEnd() {}
        func voiceCancel() { log.append("cancel") }
    }
    let (engine, _, _) = makeEngine()
    let voice = QueuedVoice()
    engine.voice = voice
    engine.talkAfterDelay = 0
    engine.keyMap = KeyMap(bindings: [
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: .single, action: .none, talkAfter: true),
    ])
    voice.log.removeAll()
    voice.atReadyCheck = { count in
        // 已通过任务入口的代次检查，在延迟开始前改映射，命中延迟后的二次检查。
        if count == 1 { engine.keyMap = KeyMap() }
    }
    input(engine, .trigger)
    // 按条件等，引擎少查一次时是测试失败，而不是永远挂住。
    try await waitUntil { voice.checks >= 2 }
    #expect(voice.checks == 2)
    #expect(voice.log == ["cancel"])
}

@Test func 无效手势时间回退默认值而合法自定义值保留() {
    for invalid in [-1.0, 0, .nan, .infinity, .greatestFiniteMagnitude] {
        let recognizer = GestureRecognizer(timing: GestureTiming(doubleTapWindow: invalid, longPressThreshold: invalid))
        #expect(recognizer.timing == GestureTiming())
        recognizer.timing = GestureTiming(doubleTapWindow: 2, longPressThreshold: 3)
        #expect(recognizer.timing.doubleTapWindow == 2)
        #expect(recognizer.timing.longPressThreshold == 3)
    }
}

@Test func 只设置接着说话的映射也会接管按键和识别长按() {
    let keyMap = KeyMap(bindings: [
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: .long, action: .none, talkAfter: true),
    ])
    #expect(keyMap.hasBinding(talkButton, .long))
    #expect(keyMap.isMapped(talkButton))
    #expect(!KeyMap(bindings: [KeyBinding(button: talkButton, buttonLabel: "空", gesture: .single, action: .none)]).isMapped(talkButton))
}

@Test func 多设备额度按去重后的设备计算且无效额度不崩溃() {
    struct Gate: FeatureGate {
        let maxActiveControlDevices: Int
        var editionName: String { "测试" }
        var maxKeyMaps: Int { 1 }
    }
    let engine = ButtonEngine(sources: [], gate: Gate(maxActiveControlDevices: 2))
    #expect(engine.activate(["a", "a", "b"]) == ["a", "b"])
    engine.gate = Gate(maxActiveControlDevices: -1)
    #expect(engine.activate(["a"]).isEmpty)
}

/// 模拟已经松开按键、但还有转写或延迟回车没有交付的语音会话。
private final class PendingDeliveryVoice: VoiceActionHandler {
    enum Pending: Equatable, CaseIterable { case transcribing, sendReturn }
    let resultAfterEnd: Pending
    var pending: Pending?
    var isVoiceActive = false
    var checks = 0
    var canStartVoice: Bool { checks += 1; return !isVoiceActive && pending != .transcribing }
    var starts = 0
    var arms = 0
    var cancels = 0
    var deliveries = 0

    init(_ result: Pending) { resultAfterEnd = result }
    func voiceArm(_ request: VoiceRequest) {
        guard canStartVoice else { return }
        pending = nil
        arms += 1
        isVoiceActive = true
    }
    func voiceDisarm(tooShortFor threshold: Double?) { isVoiceActive = false }
    func voiceBegin(_ request: VoiceRequest) {
        guard isVoiceActive || canStartVoice else { return }
        pending = nil
        starts += 1
        isVoiceActive = true
    }
    func voiceEnd() {
        guard isVoiceActive else { return }
        isVoiceActive = false
        pending = resultAfterEnd
    }
    func voiceCancel() {
        cancels += 1
        isVoiceActive = false
        pending = nil
    }
    func deliver() {
        if pending != nil { deliveries += 1 }
        pending = nil
    }
}

private struct TwoDeviceGate: FeatureGate {
    var editionName: String { "测试" }
    var maxActiveControlDevices: Int { 2 }
    var maxKeyMaps: Int { 1 }
}

private func pendingEngine(_ pending: PendingDeliveryVoice.Pending, gesture: GestureKind = .long) -> (ButtonEngine, PendingDeliveryVoice, ManualScheduler) {
    let voice = PendingDeliveryVoice(pending)
    let scheduler = ManualScheduler()
    let engine = ButtonEngine(sources: [FakeSource()], keyMap: KeyMap(bindings: [
        KeyBinding(button: talkButton, buttonLabel: "说话", gesture: gesture,
                   action: gesture == .long ? .pushToTalk : .toggleDictation, sendAfterTalk: true),
        KeyBinding(button: delayedTalkButton, buttonLabel: "接着说话", gesture: .single, action: .none, talkAfter: true),
    ]), gate: TwoDeviceGate(), scheduler: scheduler)
    engine.voice = voice
    engine.activate(["fake:1", "fake:2"])
    if gesture == .long {
        input(engine, .down)
        scheduler.advance(to: 1)
        input(engine, .up)
    } else {
        input(engine, .trigger)
        input(engine, .trigger)
    }
    return (engine, voice, scheduler)
}

@Test @MainActor func 松开后的转写和待回车仍会被断连改映射或退出取消() async {
    for pending in PendingDeliveryVoice.Pending.allCases {
        for gesture in [GestureKind.single, .long] {
            for cancellation in ["disconnect", "keymap", "shutdown"] {
                let (engine, voice, _) = pendingEngine(pending, gesture: gesture)
                #expect(!voice.isVoiceActive && voice.pending == pending)
                switch cancellation {
                case "disconnect": engine.cancelInput(deviceID: "fake:1")
                case "keymap": engine.keyMap = KeyMap()
                default:
                    await withCheckedContinuation { continuation in engine.shutdown { continuation.resume() } }
                }
                #expect(voice.cancels == 1)
                voice.deliver()
                #expect(voice.deliveries == 0)
            }
        }
    }
}

@Test func 转写中的另一个设备不能认领旧结果或抢占说话() {
    for gesture in [GestureKind.single, .long] {
        let (engine, voice, scheduler) = pendingEngine(.transcribing, gesture: gesture)
        if gesture == .long {
            input(engine, .down, deviceID: "fake:2")
            scheduler.advance(to: 2)
            input(engine, .up, deviceID: "fake:2")
        } else {
            input(engine, .trigger, deviceID: "fake:2")
        }
        #expect(voice.starts == 1)
        #expect(voice.arms == (gesture == .long ? 1 : 0))
        engine.cancelInput(deviceID: "fake:2")
        #expect(voice.cancels == 0)
        #expect(voice.pending == .transcribing)
        engine.cancelInput(deviceID: "fake:1")
        #expect(voice.cancels == 1)
        voice.deliver()
        #expect(voice.deliveries == 0)
    }
}

@Test func 待回车期间新会话可以接管但旧回车和旧设备所有权都失效() {
    for gesture in [GestureKind.single, .long] {
        let (engine, voice, scheduler) = pendingEngine(.sendReturn, gesture: gesture)
        if gesture == .long {
            input(engine, .down, deviceID: "fake:2")
            scheduler.advance(to: 2)
        } else {
            input(engine, .trigger, deviceID: "fake:2")
        }
        #expect(voice.starts == 2)
        #expect(voice.pending == nil)
        engine.cancelInput(deviceID: "fake:1")
        #expect(voice.cancels == 0 && voice.isVoiceActive)
        engine.cancelInput(deviceID: "fake:2")
        #expect(voice.cancels == 1)
        voice.deliver()
        #expect(voice.deliveries == 0)
    }
}

@Test @MainActor func 转写中的直接语音和延迟说话动作都不能覆盖旧所有权() async throws {
    let (engine, voice, _) = pendingEngine(.transcribing)
    engine.talkAfterDelay = 0
    _ = await engine.perform(.toggleDictation)
    let checks = voice.checks
    input(engine, .trigger, button: delayedTalkButton, deviceID: "fake:2")
    // 等后台任务真的查过；没等到就往下走，后面的取消会让它直接退出，这条测试等于没测。
    try await waitUntil { voice.checks > checks }
    #expect(voice.starts == 1 && voice.pending == .transcribing)
    engine.cancelInput(deviceID: "fake:2")
    #expect(voice.cancels == 0)
    engine.cancelInput(deviceID: "fake:1")
    #expect(voice.cancels == 1)
}

@Test @MainActor func 没有设备所有权的待交付任务也会被全局取消一次() async {
    for pending in PendingDeliveryVoice.Pending.allCases {
        for shutdown in [false, true] {
            let voice = PendingDeliveryVoice(pending)
            voice.pending = pending
            let engine = ButtonEngine(sources: [FakeSource()], gate: TwoDeviceGate())
            engine.voice = voice
            engine.activate(["fake:1", "fake:2"])
            if shutdown {
                await withCheckedContinuation { continuation in engine.shutdown { continuation.resume() } }
            } else {
                engine.keyMap.name = "新方案"
            }
            #expect(voice.cancels == 1)
            voice.deliver()
            #expect(voice.deliveries == 0)
        }
    }
}
