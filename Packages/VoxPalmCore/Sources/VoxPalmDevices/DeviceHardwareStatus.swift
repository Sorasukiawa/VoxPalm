import Foundation

/// 只用于当前界面的设备状态，不编码进设置或分享报告。
public struct DeviceBattery: Equatable, Sendable {
    public enum State: String, Sendable { case unknown, discharging, charging, full, error }
    public let percent: Int?
    public let state: State
    public let approximate: Bool

    public init?(percent: Int?, state: State, approximate: Bool = false) {
        guard percent.map({ (0...100).contains($0) }) ?? true else { return nil }
        self.percent = state == .error ? nil : (state == .full ? 100 : percent)
        self.state = state
        self.approximate = approximate
    }

    public var title: String {
        guard let percent else { return state == .error ? "电池状态异常" : "未提供" }
        return (approximate && percent != 100 ? "约 " : "") + "\(percent)%"
    }
    public var detail: String {
        switch state {
        case .unknown: return "充电状态未提供"
        case .discharging: return "使用电池"
        case .charging: return "充电中"
        case .full: return "已充满"
        case .error: return "设备报告异常，未估算电量"
        }
    }
}

public struct DeviceFirmwareGuide: Equatable, Sendable {
    public let summary: String
    public let url: URL
    public init(summary: String, url: URL) { self.summary = summary; self.url = url }
}

public struct DeviceHardwareStatus: Equatable, Sendable {
    public var transport: String
    public var battery: DeviceBattery?
    public var rssi: Int?
    public var firmware: String?
    public var firmwareNote: String?
    public var updateGuide: DeviceFirmwareGuide?
    public var observedAt: Date?
    public var problem: String?

    public init(transport: String = "未知", battery: DeviceBattery? = nil, rssi: Int? = nil,
                firmware: String? = nil, firmwareNote: String? = nil,
                updateGuide: DeviceFirmwareGuide? = nil, observedAt: Date? = nil, problem: String? = nil) {
        self.transport = transport; self.battery = battery; self.rssi = rssi; self.firmware = firmware
        self.firmwareNote = firmwareNote; self.updateGuide = updateGuide; self.observedAt = observedAt; self.problem = problem
    }

    public var isBluetooth: Bool { transport.localizedCaseInsensitiveContains("Bluetooth") || transport == "蓝牙" }
    public var signalTitle: String {
        if let rssi { return "\(rssi) dBm" }
        return isBluetooth || transport == "未知" ? "未提供" : "不适用"
    }
    public var signalDetail: String {
        guard let rssi else {
            if transport == "未知" { return "此来源没有提供信号信息" }
            return isBluetooth ? "系统未返回有效信号读数" : "当前不是蓝牙连接"
        }
        switch rssi {
        case (-60)...: return "信号较强"
        case -80 ..< -60: return "信号一般"
        default: return "信号较弱"
        }
    }

    /// 私有来源补充已经读到的版本等信息；nil 不能抹掉通用来源的有效读数。
    public mutating func supplement(_ other: Self?) {
        guard let other else { return }
        if let value = other.battery { battery = value }
        if let value = other.rssi { rssi = value }
        if let value = other.firmware { firmware = value; firmwareNote = other.firmwareNote }
        if let value = other.updateGuide { updateGuide = value }
    }
}

/// 公开状态字段的独立解析；输入必须包含报告编号。不会生成任何输出或固件写入。
public enum DeviceStatusValues {
    public static func rssi(_ value: Int) -> Int? { (-127...126).contains(value) ? value : nil }

    /// 系统 getter 没有成功标志；零值无法与未就绪的占位区分，保守显示未知。
    /// 带有效性信息的其他来源仍可使用 rssi(_:) 接收真实的零值。
    public static func systemRSSI(_ value: Int) -> Int? { value == 0 ? nil : rssi(value) }

    public static func controllerBattery(report: [UInt8]) -> DeviceBattery? {
        let position: Int
        switch (report.first, report.count) {
        case (0x01, 64): position = 53
        case (0x31, 78):
            guard report[1] & 2 == 0, validBluetoothReport(report) else { return nil }
            position = 54
        default: return nil
        }
        let bucket = Int(report[position] & 15), mode = report[position] >> 4
        switch mode {
        case 0, 1:
            guard bucket <= 10 else { return nil }
            return DeviceBattery(percent: min(100, bucket * 10 + 5), state: mode == 1 ? .charging : .discharging, approximate: true)
        case 2: return DeviceBattery(percent: 100, state: .full)
        case 10, 11, 15: return DeviceBattery(percent: nil, state: .error)
        default: return nil
        }
    }

    public static func controllerFirmware(report: [UInt8]) -> String? {
        guard report.count == 64, report.first == 0x20 else { return nil }
        let version = UInt16(report[44]) | UInt16(report[45]) << 8
        guard version != 0, version != .max else { return nil }
        return String(format: "0x%04X", version)
    }

    public static func bluetoothAddress(in value: String) -> String? {
        let pattern = "(?i)(?<![0-9a-f])(?:[0-9a-f]{2}[:-]){5}[0-9a-f]{2}(?![0-9a-f])"
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range, in: value) else { return nil }
        return value[range].replacingOccurrences(of: "-", with: ":").uppercased()
    }

    private static func validBluetoothReport(_ bytes: [UInt8]) -> Bool {
        var sum: UInt32 = .max
        for byte in [UInt8(0xA1)] + bytes.dropLast(4) {
            sum ^= UInt32(byte)
            for _ in 0..<8 { sum = (sum >> 1) ^ (sum & 1 == 0 ? 0 : 0xEDB8_8320) }
        }
        let expected = bytes.suffix(4).enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << ($1.offset * 8) }
        return ~sum == expected
    }
}
