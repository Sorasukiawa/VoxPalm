import Foundation
import Testing
@testable import VoxPalmEngine

private func usbReport(_ a: UInt8 = 8, _ b: UInt8 = 0, _ c: UInt8 = 0) -> [UInt8] {
    var report = [UInt8](repeating: 0, count: 64)
    report[0] = 1
    report[1...4] = [128, 128, 128, 128]
    report[8] = a; report[9] = b; report[10] = c
    return report
}

private func names(_ names: [String]) -> Set<ButtonID> { Set(names.map(DualSenseInput.button)) }

@Test func USB手柄报告正确区分方向与按键() {
    #expect(DualSenseInput.pressed(reportID: 1, bytes: usbReport(), edge: false) == [])
    // 东北方向、叉键、L1、R2、L3、触摸板按下；计数器和传感器数据不应变成按键。
    var report = usbReport(0x21, 0x49, 0x02)
    report[7] = 0xFF; report[12] = 0xFF
    #expect(DualSenseInput.pressed(reportID: 1, bytes: report, edge: false) == names(["up", "right", "cross", "l1", "r2", "l3", "touchpad"]))
}

@Test func 蓝牙基础报告不能沿用USB偏移或读出Edge额外键() {
    let report: [UInt8] = [1, 128, 128, 128, 128, 0x84, 0x20, 0xF1, 0, 0]
    #expect(DualSenseInput.pressed(reportID: 1, bytes: report, edge: true) == names(["down", "triangle", "options", "ps"]))
}

@Test func 蓝牙增强报告验校验和且只给Edge四个额外键() {
    // 独立用 zlib.crc32(0xA1 + 前74字节) 生成的固定输入样本。
    var report = [UInt8](repeating: 0, count: 78)
    report[0] = 0x31
    report[2...5] = [128, 128, 128, 128]
    report[9] = 0x21; report[10] = 2; report[11] = 0xF2
    report[74...77] = [0x91, 0x45, 0x19, 0xA0]
    let common = names(["up", "right", "cross", "r1", "touchpad"])
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: report, edge: false) == common)
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: report, edge: true) == common.union(names(["fnLeft", "fnRight", "backLeft", "backRight"])))
    report[11] = 0
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: report, edge: true) == nil)
}

@Test func 未知或截断报告不伪造松开() {
    #expect(DualSenseInput.pressed(reportID: 1, bytes: [], edge: false) == nil)
    #expect(DualSenseInput.pressed(reportID: 1, bytes: Array(usbReport().prefix(11)), edge: false) == nil)
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: usbReport(), edge: false) == nil)
    #expect(DualSenseInput.pressed(reportID: 256, bytes: usbReport(), edge: false) == nil)
}

@Test func 有效音频包不能变成手柄按键或伪造松开() {
    let audio = [UInt8(0x31), 0x02, 0x42] + [UInt8](repeating: 0xE1, count: 71) + [146, 103, 83, 58]
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: audio, edge: true) == nil)
    #expect(DualSenseInput.pressed(reportID: 0x31, bytes: audio, edge: false) == nil)
}

@Test func 重复报告去重且对角切换先松开旧方向() {
    var state = HIDButtonState()
    let first = state.update(names(["up", "right"]), deviceID: "a", time: 0, label: DualSenseInput.label)
    #expect(first.count == 2)
    #expect(state.update(names(["up", "right"]), deviceID: "a", time: 1, label: DualSenseInput.label).isEmpty)
    let next = state.update(names(["down", "right"]), deviceID: "a", time: 2, label: DualSenseInput.label)
    #expect(next.map(\.button) == [DualSenseInput.button("up"), DualSenseInput.button("down")])
    #expect(next.map(\.phase) == [.up, .down])
    #expect(state.update(names(["down"]), deviceID: "b", time: 3, label: DualSenseInput.label).count == 1)
    state.cancel("a")
    #expect(state.update([], deviceID: "a", time: 4, label: DualSenseInput.label).isEmpty)
    #expect(state.update([], deviceID: "b", time: 4, label: DualSenseInput.label).map(\.phase) == [.up])
}

@Test func 断线取消长按和等待中的双击而不触发动作() {
    let scheduler = ManualScheduler()
    let source = FakeSource()
    let key = DualSenseInput.button("r1")
    let map = KeyMap(bindings: [KeyBinding(button: key, buttonLabel: "R1", gesture: .long, action: .pushToTalk),
                                KeyBinding(button: key, buttonLabel: "R1", gesture: .double, action: .toggleDictation)])
    let engine = ButtonEngine(sources: [source], keyMap: map, scheduler: scheduler)
    let voice = FakeVoice(); engine.voice = voice
    engine.activate(["fake:1"])
    func input(_ phase: ButtonEvent.Phase) {
        engine.handle(ButtonEvent(deviceID: "fake:1", button: key, label: "R1", phase: phase, time: scheduler.now))
    }
    input(.down)
    engine.cancelInput(deviceID: "fake:1")
    scheduler.advance(to: 2)
    #expect(voice.log == ["arm", "cancel"])
    input(.down); scheduler.advance(to: 3)
    #expect(voice.isVoiceActive)
    engine.cancelInput(deviceID: "fake:1")
    #expect(!voice.isVoiceActive)
    #expect(voice.log.last == "cancel")
    input(.up)
    scheduler.advance(to: 4)
    #expect(voice.log.last == "cancel")
    input(.down); input(.up)
    let before = voice.log
    engine.cancelInput(deviceID: "fake:1")
    scheduler.advance(to: 5)
    #expect(voice.log == before)
}

@Test func 停用控制设备会结束其说话且不会发出单击() {
    let source = FakeSource(); let voice = FakeVoice(); let scheduler = ManualScheduler()
    let key = DualSenseInput.button("r1")
    let map = KeyMap(bindings: [KeyBinding(button: key, buttonLabel: "R1", gesture: .long, action: .pushToTalk, sendAfterTalk: true)])
    let engine = ButtonEngine(sources: [source], keyMap: map, scheduler: scheduler)
    engine.voice = voice; engine.activate(["fake:1"])
    engine.handle(ButtonEvent(deviceID: "fake:1", button: key, label: "R1", phase: .down, time: 0))
    scheduler.advance(to: 1)
    engine.activate([])
    #expect(voice.log == ["arm", "begin", "cancel"])
}

@Test @MainActor func 延迟开始说话不能接管另一个键的预录和发送设置() async throws {
    final class ArmedVoice: VoiceActionHandler {
        var isVoiceActive = false
        var begun = false
        var request = VoiceRequest()
        func voiceArm(_ request: VoiceRequest) { isVoiceActive = true; self.request = request }
        func voiceDisarm(tooShortFor threshold: Double?) { isVoiceActive = false }
        func voiceBegin(_ request: VoiceRequest) { begun = true; isVoiceActive = true; self.request = request }
        func voiceEnd() { isVoiceActive = false }
        func voiceCancel() { isVoiceActive = false }
    }
    let first = DualSenseInput.button("cross"), second = DualSenseInput.button("r1")
    let map = KeyMap(bindings: [
        KeyBinding(button: first, buttonLabel: "叉键", gesture: .single, action: .none, talkAfter: true, sendAfterTalk: true),
        KeyBinding(button: second, buttonLabel: "R1", gesture: .long, action: .pushToTalk),
    ])
    let scheduler = ManualScheduler(), voice = ArmedVoice()
    let engine = ButtonEngine(sources: [FakeSource()], keyMap: map, scheduler: scheduler)
    engine.voice = voice; engine.talkAfterDelay = 0.08; engine.activate(["fake:1"])
    engine.handle(ButtonEvent(deviceID: "fake:1", button: first, label: "叉键", phase: .trigger, time: 0))
    try await Task.sleep(nanoseconds: 20_000_000)
    engine.handle(ButtonEvent(deviceID: "fake:1", button: second, label: "R1", phase: .down, time: 0.02))
    try await Task.sleep(nanoseconds: 120_000_000)
    #expect(voice.isVoiceActive)
    #expect(!voice.begun)
    #expect(!voice.request.sendReturn)
}
