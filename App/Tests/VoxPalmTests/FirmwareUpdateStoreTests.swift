import Foundation
import Testing
import VoxPalmDevices
@testable import VoxPalm

@MainActor @Test func 固件安装暂停所有音量预览且拒绝新预览任务() {
    let first = MicMeter(), second = MicMeter()
    MicMeter.suspendForFirmwareUpdate(true)
    defer { MicMeter.suspendForFirmwareUpdate(false) }
    first.start(uid: nil)
    second.start(uid: "test-input", after: 1)
    #expect(!first.isActive && !second.isActive)
    let createdLater = MicMeter()
    createdLater.start(uid: nil)
    #expect(!createdLater.isActive)
}

private actor FirmwareGate: DeviceFirmwareProvider {
    var calls = 0
    private var continuation: CheckedContinuation<DeviceFirmwareCheck, Error>?
    nonisolated func supports(_ info: HIDDeviceInfo) -> Bool { true }
    func check(_ info: HIDDeviceInfo) async throws -> DeviceFirmwareCheck {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func prepare(_ token: UUID) async throws -> DeviceFirmwarePackage { throw NSError(domain: "test", code: 1) }
    func finish() {
        continuation?.resume(returning: DeviceFirmwareCheck(token: UUID(), installed: "1", latest: "1", comparison: .current,
            checkedAt: Date(), canPrepare: false, explanation: "test"))
        continuation = nil
    }
}

private func firmwareDevice(_ id: Int) throws -> HIDDeviceInfo {
    try JSONDecoder().decode(HIDDeviceInfo.self, from: Data("{\"id\":\(id),\"usagePairs\":[],\"isBuiltIn\":false}".utf8))
}

@MainActor @Test func 固件检查不会自动运行或并发堆积且断开后丢弃结果() async throws {
    let gate = FirmwareGate(), store = FirmwareUpdateStore(provider: FirmwareGate())
    let subject = FirmwareUpdateStore(provider: gate), device = try firmwareDevice(1)
    store.configure(["one": device]); subject.configure(["one": device])
    #expect(await gate.calls == 0)
    subject.check(id: "one", device: device)
    for _ in 0..<100 where await gate.calls == 0 { try await Task.sleep(for: .milliseconds(2)) }
    subject.check(id: "one", device: device)
    #expect(await gate.calls == 1)
    subject.configure(["one": try firmwareDevice(2)])
    await gate.finish()
    for _ in 0..<100 where subject.busyID != nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(subject.busyID == nil && subject.results.isEmpty)
}

@MainActor @Test func 固件查询超时后仍只允许一个在途操作() async throws {
    let gate = FirmwareGate(), device = try firmwareDevice(1)
    let store = FirmwareUpdateStore(provider: gate, timeout: .milliseconds(20))
    store.configure(["one": device]); store.check(id: "one", device: device)
    for _ in 0..<100 where store.results["one"]?.problem == nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(store.results["one"]?.problem != nil && store.busyID != nil)
    store.check(id: "one", device: device)
    #expect(await gate.calls == 1)
    await gate.finish()
    for _ in 0..<100 where store.busyID != nil { try await Task.sleep(for: .milliseconds(2)) }
    #expect(store.results["one"]?.check == nil && store.busyID == nil)
}

private actor InstallationGate: DeviceFirmwareProvider {
    var installations = 0
    private var continuation: CheckedContinuation<String, Error>?
    nonisolated func supports(_ info: HIDDeviceInfo) -> Bool { true }
    func check(_ info: HIDDeviceInfo) async throws -> DeviceFirmwareCheck {
        DeviceFirmwareCheck(token: UUID(), installed: "1", latest: "2", comparison: .available,
                            checkedAt: Date(), canPrepare: true, explanation: "test")
    }
    func prepare(_ token: UUID) async throws -> DeviceFirmwarePackage {
        DeviceFirmwarePackage(version: "2", byteCount: 10, sha256: "test", explanation: "test", experimentalInstallation: true)
    }
    func install(_ token: UUID, progress: @escaping @Sendable (DeviceFirmwareProgress) -> Void) async throws -> String {
        installations += 1
        progress(DeviceFirmwareProgress(message: "writing", completed: 1, total: 2))
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(success: Bool) {
        if success { continuation?.resume(returning: "2") }
        else { continuation?.resume(throwing: FirmwareInstallationUnavailable()) }
        continuation = nil
    }
}

@MainActor @Test func 安装期间重连不会取消安装且结果只采纳一次() async throws {
    for success in [true, false] {
        let gate = InstallationGate(), store = FirmwareUpdateStore(provider: InstallationGate())
        let subject = FirmwareUpdateStore(provider: gate), device = try firmwareDevice(1)
        store.configure(["one": device]); subject.configure(["one": device])
        subject.check(id: "one", device: device)
        for _ in 0..<100 where subject.busyID != nil { try await Task.sleep(for: .milliseconds(2)) }
        subject.prepare(id: "one")
        for _ in 0..<100 where subject.busyID != nil { try await Task.sleep(for: .milliseconds(2)) }
        var completion: Bool?
        #expect(subject.install(id: "one") { completion = $0 })
        #expect(!subject.install(id: "one") { _ in Issue.record("duplicate installation") })
        for _ in 0..<100 where await gate.installations == 0 { try await Task.sleep(for: .milliseconds(2)) }
        subject.configure([:])
        subject.configure(["one": try firmwareDevice(2)])
        #expect(subject.isInstalling && subject.busyID == "one")
        await gate.finish(success: success)
        for _ in 0..<100 where subject.busyID != nil { try await Task.sleep(for: .milliseconds(2)) }
        #expect(completion == success && !subject.isInstalling && subject.busyID == nil)
        #expect((subject.results["one"]?.installedVersion == "2") == success)
        #expect((subject.results["one"]?.problem != nil) != success)
        #expect(subject.results["one"]?.package == nil)
        #expect(await gate.installations == 1)
    }
}
