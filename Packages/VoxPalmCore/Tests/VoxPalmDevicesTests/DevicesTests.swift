import Testing
@testable import VoxPalmDevices

@Test func 遮蔽蓝牙地址只留前三段() {
    #expect(Redaction.maskBluetoothAddresses("E4-7A-2C-42-63-DB:input") == "E4-7A-2C-xx-xx-xx:input")
    #expect(Redaction.maskBluetoothAddresses("e4:7a:2c:42:63:db") == "e4:7a:2c:xx:xx:xx")
    #expect(Redaction.maskBluetoothAddresses("BuiltInMicrophoneDevice") == "BuiltInMicrophoneDevice")
}

@Test func HID用途名字() {
    #expect(HIDUsageNames.describe(page: 0x0C, usage: 0xCD) == "Consumer · Play/Pause")
    #expect(HIDUsageNames.usage(page: 0x07, usage: 0x28) == "Return")
    #expect(HIDUsageNames.usage(page: 0x07, usage: 0x04) == "a")
    #expect(MediaKeyNames.name(16) == "Play/Pause")
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
