import Foundation
import IOKit
import IOKit.hid
import GameController
@preconcurrency import IOBluetooth

public struct ControllerBatteryReading: Sendable {
    public let name: String
    public let battery: DeviceBattery
    public init(name: String, battery: DeviceBattery) { self.name = name; self.battery = battery }
}

/// 只读状态。调用方在后台串行读取；不会扫描、配对、连接设备、开麦或写固件。
public enum DeviceStatusReader {
    /// 多个接口只有都具备相同物理身份，才可以共享状态。
    public static func uniqueHID(_ infos: [HIDDeviceInfo]) -> HIDDeviceInfo? {
        guard let first = infos.first else { return nil }
        if infos.count == 1 { return first }
        guard let token = first.instanceToken, !token.isEmpty,
              infos.allSatisfy({ $0.instanceToken == token }) else { return nil }
        return first
    }

    @MainActor public static func controllerBatteries() -> [ControllerBatteryReading] {
        GCController.controllers().compactMap { controller in
            guard let name = controller.vendorName, let value = controller.battery,
                  value.batteryState != .unknown, value.batteryLevel.isFinite,
                  (0...1).contains(value.batteryLevel) else { return nil }
            let state: DeviceBattery.State
            switch value.batteryState {
            case .charging: state = .charging
            case .full: state = .full
            case .discharging: state = .discharging
            default: return nil
            }
            guard let battery = DeviceBattery(percent: Int((value.batteryLevel * 100).rounded()), state: state, approximate: true) else { return nil }
            return ControllerBatteryReading(name: name, battery: battery)
        }
    }

    /// 系统框架不提供 HID 身份，只有两侧都唯一时才按名称对应，不能把一只的电量套到另一只。
    public static func uniqueBattery(name: String, hardwareNames: [String], readings: [ControllerBatteryReading]) -> DeviceBattery? {
        func normalized(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let key = normalized(name)
        guard !key.isEmpty, hardwareNames.filter({ normalized($0) == key }).count == 1 else { return nil }
        let matches = readings.filter { normalized($0.name) == key }
        return matches.count == 1 ? matches[0].battery : nil
    }

    public static func hid(_ info: HIDDeviceInfo, queryUSBReports: Bool = false) -> DeviceHardwareStatus {
        var result = DeviceHardwareStatus(transport: info.transport ?? "未知", observedAt: Date())
        if info.profile?.isGamepad == true {
            result.updateGuide = DeviceFirmwareGuide(summary: "当前可通过 PS5 或 Windows 的 PlayStation Accessories 更新；掌声暂不支持直接升级。",
                url: URL(string: "https://controller.dl.playstation.net/controller/lang/en/2100004.html")!)
            result.firmwareNote = result.isBluetooth ? "连接 USB 后读取固件版本" : "选择设备或点刷新读取版本"
        }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(info.id))
        guard service != 0 else { result.problem = "设备已断开"; return result }
        defer { IOObjectRelease(service) }
        guard let device = IOHIDDeviceCreate(kCFAllocatorDefault, service) else { result.problem = "设备状态暂不可读"; return result }
        func number(_ key: String) -> Int? { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue }
        guard number(kIOHIDVendorIDKey) == info.vendorID, number(kIOHIDProductIDKey) == info.productID else {
            result.problem = "设备连接已变化"; return result
        }
        if let percent = number("BatteryPercent") {
            result.battery = DeviceBattery(percent: percent, state: .unknown)
        }
        if result.isBluetooth,
           let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String,
           let address = DeviceStatusValues.bluetoothAddress(in: serial) {
            result.rssi = bluetoothRSSI(address: address)
        }
        // 不对已被音频扩展接管的蓝牙连接额外发查询。
        guard queryUSBReports, info.transport == "USB", info.profile?.isGamepad == true else { return result }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            result.firmwareNote = "设备暂不可读取，稍后重试"; return result
        }
        defer { IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        if let bytes = read(device, type: kIOHIDReportTypeInput, id: 0x01) {
            result.battery = DeviceStatusValues.controllerBattery(report: bytes) ?? result.battery
        }
        if let bytes = read(device, type: kIOHIDReportTypeFeature, id: 0x20),
           let version = DeviceStatusValues.controllerFirmware(report: bytes) {
            result.firmware = version; result.firmwareNote = "设备报告的原始版本标识"
        } else { result.firmwareNote = "设备没有返回有效固件版本" }
        return result
    }

    public static func audio(_ info: AudioDeviceInfo) -> DeviceHardwareStatus {
        var result = DeviceHardwareStatus(transport: info.transport, observedAt: Date())
        if info.isBluetooth, let address = DeviceStatusValues.bluetoothAddress(in: info.uid) {
            result.rssi = bluetoothRSSI(address: address)
        }
        return result
    }

    public static func bluetoothRSSI(address: String) -> Int? {
        guard let device = IOBluetoothDevice(addressString: address), device.isConnected() else { return nil }
        return DeviceStatusValues.systemRSSI(Int(device.rawRSSI()))
    }

    private static func read(_ device: IOHIDDevice, type: IOHIDReportType, id: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: 64); bytes[0] = UInt8(id)
        var count = bytes.count
        guard IOHIDDeviceGetReport(device, type, CFIndex(id), &bytes, &count) == kIOReturnSuccess,
              count == 64, bytes.first == UInt8(id) else { return nil }
        return bytes
    }
}
