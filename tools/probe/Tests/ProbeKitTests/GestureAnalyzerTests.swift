import Testing
import Foundation
import CryptoKit
import VoxPalmDevices
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

@Test func 报告里的设备摘要换成只在这份报告有效的值() throws {
    let token = SHA256.hash(data: Data("a1-b2-c3-12-34-56".utf8)).map { String(format: "%02x", $0) }.joined()
    let json = #"{"id":1,"vendorID":1356,"productID":3570,"product":"DualSense Edge Wireless Controller","transport":"Bluetooth","usagePairs":[],"isBuiltIn":false,"instanceToken":"\#(token)"}"#
    let device = try JSONDecoder().decode(HIDDeviceInfo.self, from: Data(json.utf8))
    var report = ProbeReport(device: .init(name: "测试设备"))
    report.hidDevices = [device, device]
    func tokens(_ data: Data) throws -> [String?] {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let devices = try #require(object["hidDevices"] as? [[String: Any]])
        return devices.map { $0["instanceToken"] as? String }
    }
    let shared = try report.jsonData()
    #expect(!String(decoding: shared, as: UTF8.self).contains(token))
    let first = try tokens(shared)
    #expect(first.count == 2 && first[0] != nil && first[0] == first[1])
    #expect(try tokens(report.jsonData())[0] != first[0])
    #expect(String(decoding: try report.jsonData(redact: false), as: UTF8.self).contains(token))
    #expect(report.hidDevices[0].instanceToken == token)
}

@Test func 报告里的USB声卡序列号不原样导出() throws {
    let uid = "AppleUSBAudioEngine:Example Audio:USB Mic:SN0123456789:1"
    var report = ProbeReport(device: .init(name: "测试设备"))
    report.connectionTest = .analyze([ProbeEvent(t: 1, channel: .device, device: "USB 麦", deviceKey: uid, control: "音频设备", phase: .added)])
    #expect(!String(decoding: try report.jsonData(), as: UTF8.self).contains("SN0123456789"))
    #expect(String(decoding: try report.jsonData(redact: false), as: UTF8.self).contains(uid))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-probe-test-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    for file in try report.write(to: directory) {
        #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("SN0123456789"))
    }
}
