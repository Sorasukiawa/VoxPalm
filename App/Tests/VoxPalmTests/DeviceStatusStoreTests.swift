import Foundation
import Testing
import VoxPalmDevices
@testable import VoxPalm

private final class StatusReadGate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func read(_ request: DeviceStatusReadRequest) -> [String: DeviceHardwareStatus] {
        lock.lock(); count += 1; lock.unlock()
        _ = release.wait(timeout: .now() + 2)
        return request.targets.mapValues { _ in DeviceHardwareStatus(firmware: "test-version") }
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}

@MainActor @Test func 设备重连后的迟到状态不会覆盖当前设备() async throws {
    let gate = StatusReadGate(); defer { gate.release.signal() }
    let store = DeviceStatusStore(reader: { gate.read($0) })
    let targets: [String: HardwareStatusTarget] = ["one": .unavailable("old-connection")]
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: nil, force: true)
    try await waitUntil { gate.calls == 1 }
    store.configure(["one": .unavailable("new-connection")])
    #expect(!store.isRefreshing)
    gate.release.signal()
    try await waitUntil { !store.isBusy }
    #expect(store.values["one"] == nil)
}

@MainActor @Test func 超时查询不堆积也不采用迟到结果() async throws {
    let gate = StatusReadGate(); defer { gate.release.signal() }
    let store = DeviceStatusStore(reader: { gate.read($0) }, timeout: .milliseconds(20))
    let targets: [String: HardwareStatusTarget] = ["one": .unavailable("connection")]
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: nil, force: true)
    try await waitUntil { store.problem != nil }
    #expect(store.isBusy && !store.isRefreshing)
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: nil, force: true)
    #expect(gate.calls == 1)
    gate.release.signal()
    try await waitUntil { !store.isBusy }
    #expect(store.values.isEmpty)
}

@MainActor @Test func 断开时清除已读取状态() async throws {
    let store = DeviceStatusStore(reader: { request in request.targets.mapValues { _ in DeviceHardwareStatus(firmware: "test") } })
    store.refresh(targets: ["one": .unavailable("connection")], batteries: [], supplements: [:], queryUSBDeviceID: nil, force: true)
    try await waitUntil { !store.isBusy }
    #expect(store.values["one"]?.firmware == "test")
    store.configure([:])
    #expect(store.values.isEmpty)
}

@MainActor @Test func 忙碌时切换设备可以由下一次刷新补读() async throws {
    let gate = StatusReadGate(); defer { gate.release.signal() }
    let store = DeviceStatusStore(reader: { gate.read($0) })
    let targets: [String: HardwareStatusTarget] = ["one": .unavailable("one"), "two": .unavailable("two")]
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: "one", force: true)
    try await waitUntil { gate.calls == 1 }
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: "two", force: true)
    #expect(gate.calls == 1)
    gate.release.signal()
    try await waitUntil { !store.isBusy }
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: "two", force: false)
    try await waitUntil { gate.calls == 2 }
    gate.release.signal()
    try await waitUntil { !store.isBusy }
    store.refresh(targets: targets, batteries: [], supplements: [:], queryUSBDeviceID: "two", force: false)
    #expect(!store.isBusy && gate.calls == 2)
}
