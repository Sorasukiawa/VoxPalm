import CoreGraphics
import Testing
@testable import VoxPalmDevices

@Test func 系统暂停监听会取消按住状态且不转成按键() throws {
    let monitor = SystemEventMonitor()
    var cancellations = 0
    var events = 0
    monitor.onInputCancelled = { cancellations += 1 }
    monitor.onEvent = { _ in events += 1 }
    let event = try #require(CGEvent(source: nil))
    // 直接交给解析入口；不安装系统监听、不发送任何事件。
    for type in [CGEventType.tapDisabledByTimeout, .tapDisabledByUserInput] {
        #expect(monitor.handle(type: type, event: event) != nil)
    }
    #expect(cancellations == 2)
    #expect(events == 0)
    #expect(!monitor.isRunning)
}
