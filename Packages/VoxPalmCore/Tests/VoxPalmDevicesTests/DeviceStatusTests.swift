import Foundation
import Testing
@testable import VoxPalmDevices

@Test func 手柄电量解析保留充电与近似精度() throws {
    var report = [UInt8](repeating: 0, count: 64); report[0] = 1; report[53] = 0x18
    let charging = try #require(DeviceStatusValues.controllerBattery(report: report))
    #expect(charging.percent == 85 && charging.state == .charging && charging.approximate)
    #expect(charging.title == "约 85%")
    report[53] = 0
    #expect(DeviceStatusValues.controllerBattery(report: report)?.percent == 5)
    #expect(DeviceStatusValues.controllerBattery(report: report)?.state == .discharging)
    report[53] = 0x20
    #expect(DeviceStatusValues.controllerBattery(report: report)?.percent == 100)
    #expect(DeviceStatusValues.controllerBattery(report: report)?.state == .full)
    report[53] = 0xA8
    #expect(DeviceStatusValues.controllerBattery(report: report)?.percent == nil)
    #expect(DeviceStatusValues.controllerBattery(report: report)?.state == .error)
    report[53] = 0x1F
    #expect(DeviceStatusValues.controllerBattery(report: report) == nil)
    report[53] = 0x38
    #expect(DeviceStatusValues.controllerBattery(report: report) == nil)
}

@Test func 蓝牙电量只接收完整且校验通过的按键报告() {
    // 校验值由独立的 zlib 工具生成，不在测试里复制被测 CRC 算法。
    var valid = [UInt8](repeating: 0, count: 78)
    valid[0] = 0x31; valid[1] = 1; valid[54] = 6
    valid.replaceSubrange(74..<78, with: [0x46, 0x90, 0x73, 0x6f])
    #expect(DeviceStatusValues.controllerBattery(report: valid)?.percent == 65)
    var bad = valid; bad[20] = 1
    #expect(DeviceStatusValues.controllerBattery(report: bad) == nil)
    var audio = valid; audio[1] = 3
    audio.replaceSubrange(74..<78, with: [0x1b, 0x2e, 0x9a, 0x5b])
    #expect(DeviceStatusValues.controllerBattery(report: audio) == nil)
    #expect(DeviceStatusValues.controllerBattery(report: Array(valid.dropLast())) == nil)
    #expect(DeviceStatusValues.controllerBattery(report: [1] + Array(repeating: 0, count: 9)) == nil)
}

@Test func 不可用信号与固件不是零值或最新版本() {
    #expect(DeviceStatusValues.rssi(127) == nil)
    #expect(DeviceStatusValues.rssi(-128) == nil)
    #expect(DeviceStatusValues.rssi(-54) == -54)
    #expect(DeviceHardwareStatus(transport: "USB").signalTitle == "不适用")
    #expect(DeviceHardwareStatus(transport: "Bluetooth").signalTitle == "未提供")
    var report = [UInt8](repeating: 0, count: 64); report[0] = 0x20
    #expect(DeviceStatusValues.controllerFirmware(report: report) == nil)
    report[44] = 0x17; report[45] = 2
    #expect(DeviceStatusValues.controllerFirmware(report: report) == "0x0217")
    #expect(DeviceStatusValues.controllerFirmware(report: Array(report.dropLast())) == nil)
    report[0] = 1
    #expect(DeviceStatusValues.controllerFirmware(report: report) == nil)
    #expect(DeviceBattery(percent: -1, state: .unknown) == nil)
    #expect(DeviceBattery(percent: 101, state: .unknown) == nil)
}

@Test func 同型号多设备不共享猜测的系统电量() throws {
    let battery = try #require(DeviceBattery(percent: 85, state: .charging, approximate: true))
    let reading = ControllerBatteryReading(name: "DualSense Edge Wireless Controller", battery: battery)
    let name = "DualSense Edge Wireless Controller"
    #expect(DeviceStatusReader.uniqueBattery(name: name, hardwareNames: [name], readings: [reading]) == battery)
    #expect(DeviceStatusReader.uniqueBattery(name: name, hardwareNames: [name, name], readings: [reading]) == nil)
    #expect(DeviceStatusReader.uniqueBattery(name: name, hardwareNames: [name], readings: [reading, reading]) == nil)
    #expect(DeviceStatusReader.uniqueBattery(name: "DualSense Wireless Controller", hardwareNames: [name], readings: [reading]) == nil)
}

@Test func 蓝牙身份匹配只接受完整地址且不输出到状态() {
    #expect(DeviceStatusValues.bluetoothAddress(in: "AA-BB-CC-DD-EE-FF:input") == "AA:BB:CC:DD:EE:FF")
    #expect(DeviceStatusValues.bluetoothAddress(in: "AA:BB:CC:DD:EE") == nil)
    #expect(DeviceStatusValues.bluetoothAddress(in: "not-a-device") == nil)
    #expect(DeviceStatusValues.bluetoothAddress(in: "0AA:BB:CC:DD:EE:FF") == nil)
}

@Test func 多个HID接口必须证明物理身份一致才共用状态() {
    var first = HIDDeviceInfo(id: 1, vendorID: 1, productID: 2, versionNumber: nil, product: "Device", manufacturer: nil,
                             transport: "USB", primaryUsagePage: 1, primaryUsage: 5, usagePairs: [], isBuiltIn: false, maxInputReportSize: 64)
    var second = first
    #expect(DeviceStatusReader.uniqueHID([first]) != nil)
    #expect(DeviceStatusReader.uniqueHID([first, second]) == nil)
    first.instanceToken = "first"
    #expect(DeviceStatusReader.uniqueHID([first, second]) == nil)
    second.instanceToken = "second"
    #expect(DeviceStatusReader.uniqueHID([first, second]) == nil)
    second.instanceToken = "first"
    #expect(DeviceStatusReader.uniqueHID([first, second]) != nil)
}
