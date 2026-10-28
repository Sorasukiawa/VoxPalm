import CryptoKit
import Foundation
import Testing
import VoxPalmEngine
@testable import VoxPalm

@Suite @MainActor
struct AppConfigTests {
    private func temporaryConfig() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("voxpalm-config-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("config.json")
    }

    private static func token(_ serial: String) -> String {
        SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static let edge = "hid:0x054C:0x0DF2|\(token("a1-b2-c3-12-34-56"))|Bluetooth"
    private static let otherEdge = "hid:0x054C:0x0DF2|\(token("d4-e5-f6-00-00-01"))|Bluetooth"
    private static let remote = "hid:0x1234:0x5678|翻页笔|USB"

    private func layout(_ diagram: String) -> DeviceLayout {
        var layout = DeviceLayout()
        layout.diagramID = diagram
        return layout
    }

    @Test func 导出的设置不含设备摘要和蓝牙地址() throws {
        var config = AppConfig()
        config.controlDeviceIDs = [Self.otherEdge]
        config.deviceLayouts = [Self.edge: layout("别的那台"), Self.otherEdge: layout("正在用的"), Self.remote: layout("翻页笔"),
                                "dji:mic2:A1-B2-C3-12-34-56:input": layout("无线麦")]
        config.voice.micUID = "A1-B2-C3-12-34-56:input"
        let shared = config.sharable()
        let text = String(decoding: try JSONEncoder().encode(shared), as: UTF8.self)
        #expect(!text.contains(Self.token("a1-b2-c3-12-34-56")) && !text.contains(Self.token("d4-e5-f6-00-00-01")))
        #expect(!text.contains("12-34-56"))
        #expect(shared.controlDeviceIDs == ["hid:0x054C:0x0DF2|<redacted>|Bluetooth"])
        #expect(shared.deviceLayouts["hid:0x054C:0x0DF2|<redacted>|Bluetooth"]?.diagramID == "正在用的")
        #expect(shared.deviceLayouts[Self.remote]?.diagramID == "翻页笔")
        #expect(shared.deviceLayouts["dji:mic2:<redacted>:input"]?.diagramID == "无线麦")
        #expect(shared.voice.micUID == nil)
        try shared.validate()
        // USB 麦去掉序列号留型号，内置麦原样导出，本机设置不受影响
        config.voice.micUID = "AppleUSBAudioEngine:Example Audio:USB Mic:SN0123456789:1"
        #expect(config.sharable().voice.micUID == "AppleUSBAudioEngine:Example Audio:USB Mic:<redacted>:1")
        config.voice.micUID = "BuiltInMicrophoneDevice"
        #expect(config.sharable().voice.micUID == "BuiltInMicrophoneDevice")
        #expect(config.controlDeviceIDs == [Self.otherEdge])
    }

    @Test func 导入后同型号的USB麦恰好一支才认回() {
        var config = AppConfig()
        config.voice.micUID = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:1150000:2"
        var imported = config.sharable()
        let otherPort = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:2110000:2"
        var changed = imported.resolveDevicePlaceholders(connected: [], mics: ["BuiltInMicrophoneDevice"])
        #expect(!changed)
        changed = imported.resolveDevicePlaceholders(connected: [], mics: [otherPort, config.voice.micUID!])
        #expect(!changed)
        changed = imported.resolveDevicePlaceholders(connected: [], mics: ["BuiltInMicrophoneDevice", otherPort])
        #expect(changed)
        #expect(imported.voice.micUID == otherPort)
    }

    @Test func 导入后同型号恰好一台才认回且示意图跟着走() {
        var config = AppConfig()
        config.controlDeviceIDs = [Self.edge]
        config.deviceLayouts = [Self.edge: layout("手柄"), Self.remote: layout("翻页笔")]
        let shared = config.sharable()

        var imported = shared
        // 没连着或同型号不止一台：认不准，原样留着
        var changed = imported.resolveDevicePlaceholders(connected: [Self.remote])
        #expect(!changed)
        changed = imported.resolveDevicePlaceholders(connected: [Self.edge, Self.otherEdge, Self.remote])
        #expect(!changed)
        #expect(imported == shared)
        changed = imported.resolveDevicePlaceholders(connected: [Self.otherEdge, Self.remote, "hid:0x054C:0x0DF2|\(Self.token("x"))|USB"])
        #expect(changed)
        #expect(imported.controlDeviceIDs == [Self.otherEdge])
        #expect(imported.deviceLayouts == [Self.otherEdge: layout("手柄"), Self.remote: layout("翻页笔")])
        changed = imported.resolveDevicePlaceholders(connected: [Self.otherEdge])
        #expect(!changed)

        // 本机已有这台的示意图设置时不被导入的覆盖
        var existing = shared
        existing.deviceLayouts[Self.edge] = layout("本机的")
        changed = existing.resolveDevicePlaceholders(connected: [Self.edge])
        #expect(changed)
        #expect(existing.deviceLayouts == [Self.edge: layout("本机的"), Self.remote: layout("翻页笔")])
    }

    @Test func 首次启动没有配置时用默认值但不写文件() throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigStore(url: url)
        #expect(store.initialConfig == AppConfig())
        #expect(store.loadProblem == nil)
        try store.flush()
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func 预览不预热真实麦克风并保留界面配置与正常运行选项() {
        var config = AppConfig()
        config.voice.keepMicWarm = true
        let preview = AppModel.runtimeVoiceSettings(config.voice, isPreview: true)
        #expect(!preview.keepMicWarm)
        #expect(config.voice.keepMicWarm)
        #expect(AppModel.runtimeVoiceSettings(config.voice, isPreview: false) == config.voice)
    }

    @Test func 损坏配置在普通修改和退出落盘时保持原字节() throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let damaged = Data(#"{"version":1,"keyMap":"损坏内容"}"#.utf8)
        try damaged.write(to: url)
        let store = AppConfigStore(url: url)
        #expect(store.loadProblem != nil)
        var changed = store.initialConfig
        changed.onboardingDone = true
        store.scheduleSave(changed)
        #expect(throws: (any Error).self) { try store.flush() }
        #expect(try Data(contentsOf: url) == damaged)
        #expect(store.hasPendingChanges)
    }

    @Test func 不把未来版本当成旧版本覆盖() throws {
        #expect(throws: (any Error).self) { try AppConfig.decode(Data(#"{"version":2}"#.utf8)) }
    }

    @Test func 拒绝异常时长并保留正常自定义时长() throws {
        var config = AppConfig()
        config.timing.longPressThreshold = 0
        #expect(throws: (any Error).self) { try config.validate() }
        config.timing.longPressThreshold = 2
        config.timing.doubleTapWindow = .infinity
        #expect(throws: (any Error).self) { try config.validate() }
        config.timing.doubleTapWindow = 0.1
        config.voice.warmSeconds = -1
        #expect(throws: (any Error).self) { try config.validate() }
        config.voice.warmSeconds = 0
        try config.validate()
        config.timing.longPressThreshold = 1e100
        #expect(throws: (any Error).self) { try config.validate() }
        for field in ["warmSeconds", "minimumSeconds", "restoreInputDelay", "inputMethodSendDelay"] {
            let data = Data("{\"voice\":{\"\(field)\":1e100}}".utf8)
            #expect(throws: (any Error).self) { try AppConfig.decode(data) }
        }
        #expect(throws: (any Error).self) {
            try AppConfig.decode(Data(#"{"voice":{"restoreInputDelay":-1}}"#.utf8))
        }
    }

    @Test func 拒绝重复映射标识及同键同手势() throws {
        var config = AppConfig()
        let first = KeyBinding(button: ButtonID(rawValue: "keyboard:1"), buttonLabel: "测试键", gesture: .single, action: .sendReturn)
        var duplicate = first
        duplicate.button = ButtonID(rawValue: "keyboard:2")
        config.keyMap.bindings = [first, duplicate]
        #expect(throws: (any Error).self) { try config.validate() }
        duplicate = first
        duplicate.id = UUID()
        config.keyMap.bindings = [first, duplicate]
        #expect(throws: (any Error).self) { try config.validate() }
    }

    @Test func 退出前立即落盘只保存最后一次修改() throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigStore(url: url)
        var config = AppConfig()
        config.keyMap.name = "第一次修改"
        store.scheduleSave(config)
        config.keyMap.name = "退出前最后一次修改"
        store.scheduleSave(config)
        try store.flush()
        #expect(try AppConfig.load(from: url) == config)
        #expect(!store.hasPendingChanges)
    }

    @Test func 写盘失败保留待保存设置并允许重试() throws {
        let root = try temporaryConfig().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("blocked")
        let url = parent.appendingPathComponent("config.json")
        let store = AppConfigStore(url: url)
        try Data("临时阻塞目录的测试文件".utf8).write(to: parent)
        var config = AppConfig()
        config.onboardingDone = true
        store.scheduleSave(config)
        #expect(throws: (any Error).self) { try store.flush() }
        #expect(store.hasPendingChanges)
        try FileManager.default.removeItem(at: parent)
        try store.flush()
        #expect(try AppConfig.load(from: url) == config)
        #expect(!store.hasPendingChanges)
    }

    @Test func 导入备份包括尚未保存的修改且不会被旧延迟任务覆盖() async throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigStore(url: url)
        var previous = AppConfig()
        previous.keyMap.name = "尚未落盘的用户设置"
        store.scheduleSave(previous)
        var imported = AppConfig()
        imported.keyMap.name = "导入设置"
        let backup = try store.replace(with: imported, previous: previous)
        #expect(try AppConfig.load(from: backup) == previous)
        #expect(try AppConfig.load(from: url) == imported)
        try await Task.sleep(for: .milliseconds(650))
        #expect(try AppConfig.load(from: url) == imported)
        #expect(!store.hasPendingChanges)
    }

    @Test func 导入无效配置不改文件也不清掉待保存修改() throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = AppConfigStore(url: url)
        let previous = AppConfig()
        try previous.save(to: url)
        var pending = previous
        pending.onboardingDone = true
        store.scheduleSave(pending)
        var invalid = AppConfig()
        invalid.version = 999
        #expect(throws: (any Error).self) { try store.replace(with: invalid, previous: pending) }
        #expect(try AppConfig.load(from: url) == previous)
        #expect(store.hasPendingChanges)
        try store.flush()
        #expect(try AppConfig.load(from: url) == pending)
    }

    @Test func 损坏配置经明确导入恢复时原始内容另存备份() throws {
        let url = try temporaryConfig()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let damaged = Data("未完整写入的原设置 {".utf8)
        try damaged.write(to: url)
        let store = AppConfigStore(url: url)
        let imported = AppConfig()
        var unsaved = store.initialConfig
        unsaved.keyMap.name = "原文件读坏之后的临时修改"
        store.scheduleSave(unsaved)
        let backup = try store.replace(with: imported, previous: unsaved)
        #expect(try Data(contentsOf: backup) == damaged)
        let extra = try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("config-unsaved-") }
        let unsavedURL = try #require(extra)
        #expect(try AppConfig.load(from: unsavedURL) == unsaved)
        #expect(try AppConfig.load(from: url) == imported)
        #expect(store.loadProblem == nil)
    }
}
