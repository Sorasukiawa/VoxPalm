import Testing
import Foundation
import CryptoKit
@testable import VoxPalmDevices

@Test func 遮蔽蓝牙地址只留前三段() {
    #expect(Redaction.maskBluetoothAddresses("A1-B2-C3-12-34-56:input") == "A1-B2-C3-xx-xx-xx:input")
    #expect(Redaction.maskBluetoothAddresses("a1:b2:c3:12:34:56") == "a1:b2:c3:xx:xx:xx")
    #expect(Redaction.maskBluetoothAddresses("BuiltInMicrophoneDevice") == "BuiltInMicrophoneDevice")
}

/// 和 HIDMonitor 同样的算法：假蓝牙地址的不加盐摘要
private func fakeToken(_ serial: String = "a1-b2-c3-12-34-56") -> String {
    SHA256.hash(data: Data(serial.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test func 设备标识去掉身份后只留型号和连接方式() {
    let token = fakeToken()
    #expect(Redaction.maskDeviceIdentity("hid:0x054C:0x0DF2|\(token)|Bluetooth") == "hid:0x054C:0x0DF2|<redacted>|Bluetooth")
    #expect(Redaction.maskDeviceIdentity("hid:0x004C:0x0315|registry-42|Bluetooth") == "hid:0x004C:0x0315|<redacted>|Bluetooth")
    #expect(Redaction.maskDeviceIdentity("dji:mic2:A1-B2-C3-12-34-56:input") == "dji:mic2:<redacted>:input")
    #expect(Redaction.maskDeviceIdentity("a1:b2:c3:12:34:56:input") == "<redacted>:input")
    // USB 声卡 UID 里的序列号或端口位置
    #expect(Redaction.maskDeviceIdentity("AppleUSBAudioEngine:Example Audio:USB Mic:SN0123456789:1")
            == "AppleUSBAudioEngine:Example Audio:USB Mic:<redacted>:1")
    #expect(Redaction.maskDeviceIdentity("AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:1150000:2")
            == "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:<redacted>:2")
    // 不含身份的标识原样保留
    for id in ["hid:0x1234:0x5678|翻页笔|USB", "keys:media", "BuiltInMicrophoneDevice", "AppleUSBAudioEngine:短"] {
        #expect(Redaction.maskDeviceIdentity(id) == id)
    }
}

@Test func 去掉身份的标识按型号和连接方式认回设备() {
    let masked = Redaction.maskDeviceIdentity("hid:0x054C:0x0DF2|\(fakeToken())|Bluetooth")
    #expect(Redaction.identity(masked, matches: "hid:0x054C:0x0DF2|\(fakeToken("d4-e5-f6-00-00-01"))|Bluetooth"))
    #expect(Redaction.identity(masked, matches: "hid:0x054C:0x0DF2|registry-7|Bluetooth"))
    #expect(!Redaction.identity(masked, matches: "hid:0x054C:0x0DF2|\(fakeToken())|USB"))
    #expect(!Redaction.identity(masked, matches: "hid:0x054C:0x0CE6|\(fakeToken())|Bluetooth"))
    #expect(!Redaction.identity(masked, matches: "hid:0x054C:0x0DF2||Bluetooth"))
    #expect(!Redaction.identity(masked, matches: "hid:0x054C:0x0DF2|a|b|Bluetooth"))
    let dji = Redaction.maskDeviceIdentity("dji:mic2:A1-B2-C3-12-34-56:input")
    #expect(Redaction.identity(dji, matches: "dji:mic2:D4-E5-F6-00-00-01:input"))
    #expect(!Redaction.identity(dji, matches: "dji:mic3:D4-E5-F6-00-00-01:input"))
    let usb = Redaction.maskDeviceIdentity("AppleUSBAudioEngine:Example Audio:USB Mic:SN0123456789:1")
    #expect(Redaction.identity(usb, matches: "AppleUSBAudioEngine:Example Audio:USB Mic:SN9876543210:1"))
    #expect(!Redaction.identity(usb, matches: "AppleUSBAudioEngine:Example Audio:USB Mic Pro:SN9876543210:1"))
    // 没有占位的标识只认一模一样的
    #expect(Redaction.identity("hid:0x1234:0x5678|翻页笔|USB", matches: "hid:0x1234:0x5678|翻页笔|USB"))
    #expect(!Redaction.identity("hid:0x1234:0x5678|翻页笔|USB", matches: "hid:0x1234:0x5678|翻页笔2|USB"))
}

@Test func 分享用的设备摘要每次重算且不含原值() {
    let base = HIDDeviceInfo(id: 1, vendorID: 0x054C, productID: 0x0DF2, versionNumber: nil, product: "DualSense Edge Wireless Controller",
                             manufacturer: nil, transport: "Bluetooth", primaryUsagePage: 1, primaryUsage: 5, usagePairs: [],
                             isBuiltIn: false, maxInputReportSize: 78)
    var first = base, interface = base, other = base, unknown = base
    first.instanceToken = fakeToken(); interface.instanceToken = fakeToken(); other.instanceToken = fakeToken("d4-e5-f6-00-00-01")
    unknown.instanceToken = nil
    let once = Redaction.anonymizeInstanceTokens([first, interface, other, unknown])
    #expect(once[0].instanceToken == once[1].instanceToken)
    #expect(once[0].instanceToken != once[2].instanceToken)
    #expect(once[3].instanceToken == nil)
    #expect(once[0].instanceToken?.count == 16)
    #expect(once[0].instanceToken != fakeToken())
    #expect(fakeToken().contains(once[0].instanceToken ?? "") == false)
    let again = Redaction.anonymizeInstanceTokens([first])
    #expect(again[0].instanceToken != once[0].instanceToken)
}

@Test func HID用途名字() {
    #expect(HIDUsageNames.describe(page: 0x0C, usage: 0xCD) == "Consumer · Play/Pause")
    #expect(HIDUsageNames.usage(page: 0x07, usage: 0x28) == "Return")
    #expect(HIDUsageNames.usage(page: 0x07, usage: 0x04) == "a")
    #expect(MediaKeyNames.name(16) == "Play/Pause")
}

@Test func 设备适配只认明确型号而不误认其他输入设备() {
    #expect(HIDDeviceProfile.identify(vendor: 0x004C, product: 0x0315) == .siriRemote3)
    #expect(HIDDeviceProfile.identify(vendor: 0x004C, product: 0x0314) == .siriRemote2)
    #expect(HIDDeviceProfile.identify(vendor: 0x004C, product: 0x026D) == .siriRemote1)
    #expect(HIDDeviceProfile.identify(vendor: 0x054C, product: 0x0CE6) == .dualSense)
    #expect(HIDDeviceProfile.identify(vendor: 0x054C, product: 0x0DF2) == .dualSenseEdge)
    #expect(HIDDeviceProfile.identify(vendor: 0x004C, product: 0x0269) == nil)
    #expect(HIDDeviceProfile.identify(vendor: 0x054C, product: 0x09CC) == nil)
    #expect(HIDDeviceProfile.identify(vendor: nil, product: 0x0315) == nil)
}

@Test func 同型号手柄保持独立身份且旧探针报告仍能读取() throws {
    var first = HIDDeviceInfo(id: 1, vendorID: 0x054C, productID: 0x0CE6, versionNumber: nil,
                              product: "Wireless Controller", manufacturer: nil, transport: "Bluetooth",
                              primaryUsagePage: 1, primaryUsage: 5, usagePairs: [], isBuiltIn: false, maxInputReportSize: 78)
    var second = first
    first.instanceToken = "unit-a"; second.instanceToken = "unit-b"
    #expect(first.controlKey != second.controlKey)
    var interface = first
    interface.instanceToken = first.instanceToken
    #expect(first.controlKey == interface.controlKey)
    var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(first)) as? [String: Any])
    json.removeValue(forKey: "instanceToken")
    let old = try JSONDecoder().decode(HIDDeviceInfo.self, from: JSONSerialization.data(withJSONObject: json))
    #expect(old.instanceToken == nil)
}

@Test func 同名遥控器没有硬件身份时不能合并() throws {
    let data = Data(#"{"id":1,"vendorID":76,"productID":789,"product":"Siri Remote","transport":"Bluetooth","usagePairs":[],"isBuiltIn":false}"#.utf8)
    let first = try JSONDecoder().decode(HIDDeviceInfo.self, from: data)
    let second = try JSONDecoder().decode(HIDDeviceInfo.self, from: Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\"id\":1", with: "\"id\":2").utf8))
    #expect(first.controlKey != second.controlKey)
}

@Test func 蓝牙收音协议判断() {
    func device(rate: Double, transport: String = "Bluetooth", inputs: Int = 1) -> AudioDeviceInfo {
        AudioDeviceInfo(id: 1, uid: "u", name: "n", manufacturer: nil, transport: transport, inputChannels: inputs, outputChannels: 1,
                        nominalSampleRate: rate, availableSampleRates: [[rate, rate]], inputStreamFormat: nil,
                        isDefaultInput: false, isDefaultOutput: false, isDefaultSystemOutput: false, isRunningSomewhere: false)
    }
    #expect(device(rate: 16_000).isLowRateBluetoothInput)
    #expect(device(rate: 16_000).bluetoothProfileGuess?.contains("mSBC") == true)
    #expect(device(rate: 8_000).bluetoothProfileGuess?.contains("CVSD") == true)
    #expect(!device(rate: 48_000, transport: "USB").isLowRateBluetoothInput)
    #expect(device(rate: 48_000, inputs: 0).bluetoothProfileGuess?.contains("A2DP") == true)
}

@Test func 开着麦的程序名字() {
    // 系统设置的「声音」页是单独的扩展进程，一直在量输入音量
    #expect(AudioDevices.clientName(path: "/System/Library/ExtensionKit/Extensions/Sound.appex/Contents/MacOS/Sound", appName: nil,
                                    bundleID: "com.apple.Sound-Settings.extension", pid: 1) == "系统设置 › 声音")
    // App 里带的辅助程序用外层 App 的名字
    #expect(AudioDevices.clientName(path: "/Applications/ChatGPT.app/Contents/Resources/native/system-audio-spectrum", appName: nil,
                                    bundleID: nil, pid: 2) == "ChatGPT")
    #expect(AudioDevices.clientName(path: "/Applications/Zoom.app/Contents/MacOS/zoom.us", appName: "zoom.us", bundleID: nil, pid: 3) == "zoom.us")
    #expect(AudioDevices.clientName(path: "/usr/local/bin/sox", appName: nil, bundleID: nil, pid: 4) == "sox")
    #expect(AudioDevices.clientName(path: "", appName: nil, bundleID: nil, pid: 5) == "进程 5")
}
