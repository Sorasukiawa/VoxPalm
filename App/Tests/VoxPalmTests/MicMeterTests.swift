import Testing
import VoxPalmVoice
@testable import VoxPalm

@Test @MainActor func 量音量只允许明确的系统默认或已选且存在的输入() throws {
    let uid = "AppleUSBAudioEngine:Sony Interactive Entertainment:DualSense Edge Wireless Controller:test:2"
    #expect(try MicMeter.requestedDeviceID(uid: nil) { _ in Issue.record("默认输入不应查询指定 UID"); return nil } == nil)
    #expect(try MicMeter.requestedDeviceID(uid: uid) { $0 == uid ? 42 : nil } == 42)
    // 半秒等待期间设备消失时，必须拒绝，不能把 nil 交给 AudioCapture 打开默认麦。
    #expect(throws: AudioCapture.CaptureError.self) { try MicMeter.requestedDeviceID(uid: uid) { _ in nil } }
    #expect(throws: AudioCapture.CaptureError.self) { try MicMeter.requestedDeviceID(uid: uid) { _ in 0 } }
}
