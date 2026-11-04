import Foundation
import Testing
@preconcurrency import Network
@testable import VoxPalmLinkNetwork

@MainActor private final class FaultCredentials: LinkCredentialStore {
    var values: [UUID: LinkCredential] = [:]
    var failSave = false
    var failRemove = false
    func save(_ credential: LinkCredential) throws {
        if failSave { throw SecureLinkError.storage }; values[credential.id] = credential
    }
    func load(id: UUID) throws -> LinkCredential? { values[id] }
    func remove(id: UUID) throws {
        if failRemove { throw SecureLinkError.storage }; values.removeValue(forKey: id)
    }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
}

@Test @MainActor func 待完成记录重启后不可信且能清理() throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("devices.json"), raw = FaultCredentials()
    let first = try LinkDeviceStore(url: url, credentials: raw)
    let key = try LinkCredential(hostID: first.identity, clientID: UUID())
    try first.save(key)
    let second = try LinkDeviceStore(url: url, credentials: raw)
    #expect(second.identity == first.identity)
    #expect(try second.load(id: key.id) == nil)
    #expect(second.devices.first?.state == .pending)
    try second.remove(id: key.id)
    #expect(raw.values.isEmpty); #expect(second.devices.isEmpty)
}

@Test @MainActor func 撤销删除失败仍持久禁止连接且可重试() throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("devices.json"), raw = FaultCredentials()
    let store = try LinkDeviceStore(url: url, credentials: raw)
    let key = try LinkCredential(hostID: store.identity, clientID: UUID())
    try store.save(key); try store.activate(id: key.id)
    #expect(try store.load(id: key.id)?.id == key.id)
    raw.failRemove = true
    #expect(throws: SecureLinkError.storage) { try store.remove(id: key.id) }
    let reloaded = try LinkDeviceStore(url: url, credentials: raw)
    #expect(try reloaded.load(id: key.id) == nil)
    #expect(reloaded.devices.first?.state == .removing)
    raw.failRemove = false; try reloaded.remove(id: key.id)
    #expect(reloaded.devices.isEmpty); #expect(raw.values.isEmpty)
}

@Test @MainActor func 保存失败留下可见记录且损坏目录不覆盖() throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("devices.json"), raw = FaultCredentials()
    let store = try LinkDeviceStore(url: url, credentials: raw)
    raw.failSave = true
    let key = try LinkCredential(hostID: store.identity, clientID: UUID())
    #expect(throws: SecureLinkError.storage) { try store.save(key) }
    #expect(store.devices.first?.state == .pending)
    #expect(throws: SecureLinkError.storage) { try store.activate(id: key.id) }
    let bad = Data("invalid".utf8); try bad.write(to: url)
    #expect(throws: SecureLinkError.storage) { _ = try LinkDeviceStore(url: url, credentials: raw) }
    #expect(throws: SecureLinkError.storage) { try store.remove(id: key.id) }
    #expect(try Data(contentsOf: url) == bad)
}

@Test @MainActor func 并发旧快照不能覆盖新设备记录() throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("devices.json"), raw = FaultCredentials()
    let first = try LinkDeviceStore(url: url, credentials: raw), stale = try LinkDeviceStore(url: url, credentials: raw)
    let key = try LinkCredential(hostID: first.identity, clientID: UUID())
    try first.save(key)
    #expect(throws: SecureLinkError.storage) { try stale.save(LinkCredential(hostID: stale.identity, clientID: UUID())) }
    #expect(try LinkDeviceStore(url: url, credentials: raw).devices.map(\.id) == [key.id])
    try first.activate(id: key.id)
    let other = try LinkDeviceStore(url: url, credentials: raw)
    try other.remove(id: key.id)
    #expect(throws: SecureLinkError.storage) { _ = try first.load(id: key.id) }
}

@MainActor private func eventually(_ condition: () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(8)
    while !condition() {
        guard ContinuousClock.now < until else { throw SecureLinkError.timeout }
        try await Task.sleep(for: .milliseconds(10))
    }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 界面模型完成回环配对连接测试与撤销() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let hostRaw = FaultCredentials(), clientRaw = FaultCredentials()
    let hostStore = try LinkDeviceStore(url: dir.appendingPathComponent("host.json"), credentials: hostRaw)
    let clientStore = try LinkDeviceStore(url: dir.appendingPathComponent("client.json"), credentials: clientRaw)
    let host = HostPairingModel(store: hostStore, loopbackOnly: true), client = ClientPairingModel(store: clientStore)
    defer { client.stop(); host.setEnabled(false) }
    #expect(!host.enabled); #expect(host.code == nil); #expect(hostRaw.values.isEmpty)
    host.setEnabled(true); host.beginPairing()
    try await eventually { host.code != nil && host.pairingPort != nil }
    client.pair(code: try #require(host.code), endpoint: .hostPort(host: "127.0.0.1", port: try #require(host.pairingPort)))
    try await eventually { host.devices.first?.state == .paired && client.devices.first?.state == .paired }
    let id = try #require(host.devices.first?.id)
    #expect(host.code == nil)
    try await eventually { host.ports[id] != nil }
    client.connect(id, endpoint: .hostPort(host: "127.0.0.1", port: try #require(host.ports[id])))
    try await eventually { client.connectedID == id }
    client.sendTest(); try await eventually { host.testCount == 1 }
    hostRaw.failRemove = true; host.revoke(id)
    try await eventually { client.connectedID == nil }
    #expect(host.devices.first?.state == .removing)
    #expect(try hostStore.load(id: id) == nil)
    hostRaw.failRemove = false; host.revoke(id)
    #expect(host.devices.isEmpty); #expect(hostRaw.values.isEmpty)
    client.revoke(id); #expect(client.devices.isEmpty); #expect(clientRaw.values.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func 取消邀请后旧回调不重新显示二维码() async throws {
    let dir = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: dir) }
    let store = try LinkDeviceStore(url: dir.appendingPathComponent("host.json"), credentials: FaultCredentials())
    let host = HostPairingModel(store: store, loopbackOnly: true)
    host.setEnabled(true); host.beginPairing(); host.cancelPairing()
    host.setEnabled(false)
    try await Task.sleep(for: .milliseconds(100))
    #expect(host.code == nil); #expect(host.pairingPort == nil); #expect(!host.enabled)
    let client = ClientPairingModel(store: store)
    client.pair(code: "invalid")
    #expect(!client.busy); #expect(client.connectedID == nil); #expect(client.devices.isEmpty)
}
