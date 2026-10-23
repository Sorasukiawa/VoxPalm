import Foundation
import VoxPalmDevices

public struct ProbeReport: Codable, Sendable {
    public struct MacInfo: Codable, Sendable {
        public var model: String
        public var macOS: String

        public static var current: MacInfo {
            var size = 0
            sysctlbyname("hw.model", nil, &size, nil, 0)
            var buffer = [CChar](repeating: 0, count: max(size, 1))
            sysctlbyname("hw.model", &buffer, &size, nil, 0)
            let model = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return MacInfo(model: model, macOS: ProcessInfo.processInfo.operatingSystemVersionString)
        }
    }

    public struct DeviceUnderTest: Codable, Sendable {
        public var name: String
        public var model: String?
        public var connection: String?
        public var notes: String?

        public init(name: String, model: String? = nil, connection: String? = nil, notes: String? = nil) {
            self.name = name
            self.model = model
            self.connection = connection
            self.notes = notes
        }
    }

    public struct KeyReport: Codable, Sendable {
        public var name: String
        public var gestures: [GestureResult]

        public init(name: String, gestures: [GestureResult] = []) {
            self.name = name
            self.gestures = gestures
        }
    }

    public struct ConnectionTest: Codable, Sendable {
        public var events: [ProbeEvent]
        public var defaultOutputTaken: Bool
        public var defaultInputTaken: Bool
        public var summary: String

        /// 设备连上后几秒内系统默认输出 / 输入换成了它，就算「被切走」。
        public static func analyze(_ events: [ProbeEvent]) -> ConnectionTest {
            let added = events.filter { $0.channel == .device && $0.phase == .added && $0.control == "音频设备" }
            func taken(_ control: String) -> Bool {
                events.contains { change in
                    change.channel == .audio && change.control == control && change.phase == .change
                        && added.contains { $0.deviceKey == change.deviceKey && change.t - $0.t <= 10 && change.t >= $0.t }
                }
            }
            let output = taken("系统默认输出")
            let input = taken("系统默认输入")
            var parts: [String] = []
            if added.isEmpty {
                parts.append("这段时间里没有新的音频设备连上")
            } else {
                parts.append("连上的音频设备：" + Set(added.compactMap(\.device)).sorted().joined(separator: "、"))
                parts.append(output ? "系统默认输出被它切走了" : "系统默认输出没有被切走")
                parts.append(input ? "系统默认输入切到了它" : "系统默认输入没有切到它")
            }
            return ConnectionTest(events: events, defaultOutputTaken: output, defaultInputTaken: input, summary: parts.joined(separator: "；"))
        }
    }

    public var schemaVersion = 1
    public var tool = "VoxPalm Probe \(ProbeVersion.string)"
    public var generatedAt = Date()
    public var mac = MacInfo.current
    public var device: DeviceUnderTest
    public var permissions: [String: String] = [:]
    public var channels: ProbeRecorder.ChannelStatus?
    public var hidDevices: [HIDDeviceInfo] = []
    public var audioDevices: [AudioDeviceInfo] = []
    public var captures: [CaptureMeasurement] = []
    public var connectionTest: ConnectionTest?
    public var keys: [KeyReport] = []
    public var notes: [String] = []

    public init(device: DeviceUnderTest) {
        self.device = device
    }

    // MARK: - 导出

    public func jsonData(redact: Bool = true) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        guard redact, let text = String(data: data, encoding: .utf8) else { return data }
        return Data(Redaction.maskBluetoothAddresses(text).utf8)
    }

    /// 写 report.json 和 report.md，返回两个文件的路径。
    @discardableResult
    public func write(to directory: URL, redact: Bool = true) throws -> [URL] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = directory.appendingPathComponent("report.json")
        let markdown = directory.appendingPathComponent("report.md")
        try jsonData(redact: redact).write(to: json, options: .atomic)
        let text = MarkdownRenderer.render(self)
        try (redact ? Redaction.maskBluetoothAddresses(text) : text).write(to: markdown, atomically: true, encoding: .utf8)
        return [json, markdown]
    }
}

public enum ProbeVersion {
    public static let string = "0.1.0"
}
