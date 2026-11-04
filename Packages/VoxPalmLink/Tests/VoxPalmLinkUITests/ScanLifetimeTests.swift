import Testing
@testable import VoxPalmLinkUI

@Test @MainActor func 取消立即停相机并丢弃晚到的扫码结果() {
    let scan = ScanLifetime()
    var stopped = false, paired = false
    scan.stopCamera = { stopped = true }
    scan.cancel()
    #expect(stopped)
    #expect(!scan.finish { paired = true })
    #expect(!paired)
}

@Test @MainActor func 扫码成功只消费一次且先停相机再回调() {
    let scan = ScanLifetime()
    var calls = 0, stopped = false
    scan.stopCamera = { stopped = true }
    let consumed = scan.finish { #expect(stopped); calls += 1; scan.cancel() }
    #expect(consumed)
    #expect(!scan.finish { calls += 1 })
    #expect(calls == 1)
}
