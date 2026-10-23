import Testing
@testable import VoxPalmDevices

@Test func 有报告流时不查询且每连接最多一个在途查询() throws {
    var state = HIDInputPollingState()
    state.activate(1, now: 0)
    let observed6 = state.begin(1, now: 0.2) == nil
    #expect(observed6)
    let candidate7 = state.begin(1, now: 0.3)
    let ticket = try #require(candidate7)
    let observed8 = state.begin(1, now: 0.9) == nil
    #expect(observed8)
    let observed9 = state.acceptStream(1, eventTime: 1, now: 1)
    #expect(observed9)
    let observed10 = !state.complete(ticket, now: 1.1, succeeded: true)
    #expect(observed10)
    let observed11 = state.begin(1, now: 1.2) == nil
    #expect(observed11)
    let observed12 = state.begin(1, now: 1.3) != nil
    #expect(observed12)
}

@Test func 查询之后晚到的旧流不能重放按键而新连接不继承时间下限() throws {
    var state = HIDInputPollingState()
    state.activate(1, now: 0)
    let candidate18 = state.begin(1, now: 1)
    let ticket = try #require(candidate18)
    let observed19 = state.complete(ticket, now: 1.1, succeeded: true)
    #expect(observed19)
    let observed20 = !state.acceptStream(1, eventTime: 0.9, now: 1.15)
    #expect(observed20)
    let observed21 = state.acceptStream(1, eventTime: 1.2, now: 1.21)
    #expect(observed21)
    let observed22 = !state.acceptStream(1, eventTime: 1.1, now: 1.3)
    #expect(observed22)
    state.deactivate(1)
    state.activate(1, now: 2)
    let observed25 = state.acceptStream(1, eventTime: 1.9, now: 2)
    #expect(observed25)
}

@Test func 断线重连后的旧查询不能污染新设备状态() throws {
    var state = HIDInputPollingState()
    state.activate(1, now: 0)
    let candidate31 = state.begin(1, now: 1)
    let old = try #require(candidate31)
    state.deactivate(1)
    state.activate(1, now: 2)
    let candidate34 = state.begin(1, now: 3)
    let new = try #require(candidate34)
    let observed35 = !state.complete(old, now: 4, succeeded: true)
    #expect(observed35)
    let observed36 = state.begin(1, now: 4) == nil
    #expect(observed36)
    let observed37 = state.complete(new, now: 4, succeeded: true)
    #expect(observed37)
    let observed38 = state.begin(1, now: 5) != nil
    #expect(observed38)
}

@Test func 查询失败退避且停用后拒绝晚到结果() throws {
    var state = HIDInputPollingState()
    state.activate(1, now: 0)
    let candidate44 = state.begin(1, now: 1)
    let first = try #require(candidate44)
    let observed45 = !state.complete(first, now: 1.1, succeeded: false)
    #expect(observed45)
    let observed46 = state.begin(1, now: 2) == nil
    #expect(observed46)
    let candidate47 = state.begin(1, now: 2.2)
    let next = try #require(candidate47)
    state.stop()
    let observed49 = !state.complete(next, now: 3, succeeded: true)
    #expect(observed49)
    let observed50 = state.begin(1, now: 4) == nil
    #expect(observed50)
}
