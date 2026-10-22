import Testing
@testable import ProbeKit

private func hid(_ t: Double, _ phase: ProbeEvent.Phase, control: String = "Consumer · Play/Pause") -> ProbeEvent {
    ProbeEvent(t: t, channel: .hid, device: "遥控器", deviceKey: "0x0001:0x0002|遥控器|Bluetooth", control: control, phase: phase, value: phase == .down ? 1 : 0)
}

@Test func 单击能读到按下和松开() {
    let result = GestureAnalyzer.analyze(.single, events: [hid(1.0, .down), hid(1.12, .up)])
    #expect(result.hasRelease)
    #expect(result.controls.first?.presses == 1)
    #expect(result.firmware == .none)
    #expect(result.verdict.contains("能读到按下和松开"))
}

@Test func 长按算出按住时长() {
    let result = GestureAnalyzer.analyze(.long1, events: [hid(2.0, .down), hid(3.05, .up)])
    #expect(result.longestHold == 1.05)
    #expect(result.verdict.contains("能读到按住时长"))
}

@Test func 只有一次性触发() {
    let event = ProbeEvent(t: 1, channel: .remoteCommand, control: "togglePlayPause", phase: .trigger)
    let result = GestureAnalyzer.analyze(.single, events: [event])
    #expect(!result.hasRelease)
    #expect(result.verdict.contains("没有松开"))
}

@Test func 长按发出别的键算固件改写() {
    let reference = GestureAnalyzer.analyze(.single, events: [hid(1.0, .down), hid(1.1, .up)])
    let result = GestureAnalyzer.analyze(.long3, events: [hid(5.0, .down, control: "Consumer · Menu"), hid(5.1, .up, control: "Consumer · Menu")], reference: reference)
    #expect(result.firmware == .rewritten)
    #expect(result.verdict.contains("和单击不同的键"))
}

@Test func 单击有事件而长按没有算疑似占用() {
    let reference = GestureAnalyzer.analyze(.single, events: [hid(1.0, .down), hid(1.1, .up)])
    let result = GestureAnalyzer.analyze(.long3, events: [], reference: reference)
    #expect(result.firmware == .suspected)
}

@Test func 设备断开或用户描述反应算被固件占用() {
    let removed = ProbeEvent(t: 3, channel: .device, device: "DJI", deviceKey: "x", control: "音频设备", phase: .removed)
    #expect(GestureAnalyzer.analyze(.long3, events: [removed]).firmware == .occupied)
    #expect(GestureAnalyzer.analyze(.long3, events: [], firmwareReaction: "灯变成蓝色闪烁").firmware == .occupied)
}

@Test func 连接测试识别默认输出被切走() {
    let events = [
        ProbeEvent(t: 1, channel: .device, device: "耳机", deviceKey: "uid-1", control: "音频设备", phase: .added),
        ProbeEvent(t: 2.5, channel: .audio, device: "耳机", deviceKey: "uid-1", control: "系统默认输出", phase: .change),
    ]
    let test = ProbeReport.ConnectionTest.analyze(events)
    #expect(test.defaultOutputTaken)
    #expect(!test.defaultInputTaken)
}

@Test func 报告能导出并遮掉蓝牙地址() throws {
    var report = ProbeReport(device: .init(name: "测试设备"))
    report.notes = ["UID A1-B2-C3-12-34-56:input"]
    let text = String(decoding: try report.jsonData(), as: UTF8.self)
    #expect(text.contains("A1-B2-C3-xx-xx-xx"))
    #expect(!text.contains("12-34-56"))
    let markdown = MarkdownRenderer.render(report)
    #expect(markdown.contains("# 设备探针报告：测试设备"))
}
