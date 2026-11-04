import Foundation
import Network
import Testing
import VoxPalmLink
@testable import VoxPalmLinkNetwork

@MainActor func waitFor(_ condition: () -> Bool) async throws {
    while !condition() { try await Task.sleep(for: .milliseconds(5)) }
}

@MainActor final class MemoryCredentials: LinkCredentialStore {
    var values: [UUID: LinkCredential] = [:]
    var failSave = false
    var failRemove = false
    func save(_ credential: LinkCredential) throws {
        if failSave { throw SecureLinkError.storage }
        values[credential.id] = credential
    }
    func remove(id: UUID) throws {
        if failRemove { throw SecureLinkError.storage }; values.removeValue(forKey: id)
    }
    func load(id: UUID) -> LinkCredential? { values[id] }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 配对轮换密钥后能传意图并在断开撤销时取消() async throws {
    let hostStore = MemoryCredentials(), clientStore = MemoryCredentials()
    let invitation = try PairingInvitation(hostID: UUID())
    let pairing = try PairingHost(invitation: invitation, store: hostStore, loopbackOnly: true)
    var port: NWEndpoint.Port?, hostCredential: LinkCredential?, clientCredential: LinkCredential?, failure: SecureLinkError?
    pairing.onReady = { port = $0 }; pairing.onPaired = { hostCredential = $0 }; pairing.onFailure = { failure = $0 }
    pairing.start(); defer { pairing.cancel() }
    try await waitFor { port != nil || failure != nil }; try #require(port != nil)
    let client = try PairingClient(invitation: invitation, endpoint: .hostPort(host: "127.0.0.1", port: port!), store: clientStore)
    client.onPaired = { clientCredential = $0 }; client.onFailure = { failure = $0 }; client.start()
    defer { client.cancel() }
    try await waitFor { (hostCredential != nil && clientCredential != nil) || failure != nil }
    let hc = try #require(hostCredential), cc = try #require(clientCredential)
    #expect(hc.secret == cc.secret && hc.secret != invitation.credential.secret)
    #expect(hc.id != invitation.credential.id && hostStore.values.count == 1 && clientStore.values.count == 1)
    let host = try SecureLinkHost(credential: hc, store: hostStore, loopbackOnly: true)
    var linkPort: NWEndpoint.Port?, messages: [LinkMessage] = []
    host.onReady = { linkPort = $0 }; host.onMessage = { messages.append($0) }; host.start()
    defer { host.stop() }
    try await waitFor { linkPort != nil }
    let link = SecureLinkClient(credential: cc, endpoint: .hostPort(host: "127.0.0.1", port: linkPort!))
    var ready = false, disconnected = false
    link.onReady = { ready = true }; link.onDisconnected = { _ in disconnected = true }; link.start()
    defer { link.stop() }
    try await waitFor { ready || disconnected }; try #require(ready)
    let down = LinkMessage.button(RemoteButton(id: "talk", phase: .down))
    try link.send(down); try await waitFor { messages.contains(down) }
    try host.revoke()
    try await waitFor { disconnected }
    #expect(messages.last == .button(RemoteButton(id: "talk", phase: .cancel)))
    #expect(hostStore.values.isEmpty)
    #expect(throws: SecureLinkError.connection) { try link.send(.heartbeat) }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 配对保存失败不建立信任且取消邀请不可重启() async throws {
    let hostStore = MemoryCredentials(); hostStore.failSave = true
    let clientStore = MemoryCredentials(), invitation = try PairingInvitation(hostID: UUID())
    let host = try PairingHost(invitation: invitation, store: hostStore, loopbackOnly: true)
    var port: NWEndpoint.Port?, failed = false, paired = false, clientFailed = false
    host.onReady = { port = $0 }; host.onFailure = { _ in failed = true }; host.onPaired = { _ in paired = true }
    host.start(); defer { host.cancel() }
    try await waitFor { port != nil }
    let client = try PairingClient(invitation: invitation, endpoint: .hostPort(host: "127.0.0.1", port: port!), store: clientStore)
    client.onFailure = { _ in clientFailed = true }; client.start(); defer { client.cancel() }
    try await waitFor { failed && clientFailed }
    #expect(!paired && hostStore.values.isEmpty && clientStore.values.isEmpty)
    host.start()
    #expect(!paired)
}

@Test(.timeLimit(.minutes(1))) @MainActor func 真实TLS回环能传数据且错误密钥不能就绪() async throws {
    let credential = try LinkCredential(hostID: UUID(), clientID: UUID())
    let listener = try CredentialListener(credential: credential, pairing: false, loopbackOnly: true)
    var port: NWEndpoint.Port?, received = Data(), accepted: TLSChannel?
    var listenerFailed = false
    listener.onFailure = { listenerFailed = true }
    listener.onReady = { port = $0 }
    listener.onAuthenticated = { channel in accepted = channel; channel.onData = { received.append($0) } }
    listener.start(); defer { listener.stop(); accepted?.close() }
    try await waitFor { port != nil || listenerFailed }
    try #require(port != nil)
    let client = TLSChannel(endpoint: .hostPort(host: "127.0.0.1", port: port!), credential: credential, pairing: false)
    var ready = false, closed = false
    client.onReady = { ready = true }; client.onClose = { _ in closed = true }; client.start(); defer { client.close() }
    try await waitFor { ready || closed }
    try #require(ready)
    client.send(Data("synthetic".utf8))
    try await waitFor { received == Data("synthetic".utf8) }
    let bad = try LinkCredential(id: credential.id, hostID: credential.hostID, clientID: credential.clientID, secret: Data(repeating: 0, count: 32))
    let wrong = TLSChannel(endpoint: .hostPort(host: "127.0.0.1", port: port!), credential: bad, pairing: false)
    var rejected = false, wronglyReady = false
    wrong.onReady = { wronglyReady = true }; wrong.onClose = { _ in rejected = true }; wrong.start()
    defer { wrong.close() }
    try await waitFor { rejected }
    #expect(!wronglyReady)
    client.send(Data(count: 65_541))
    #expect(closed)
}

@Test func 配对码解析边界与密钥脱敏() throws {
    let now = Date(), invitation = try PairingInvitation(hostID: UUID(), now: now)
    let code = try invitation.pairingCode()
    let decoded = try PairingInvitation(code: code, now: now)
    #expect(decoded.serviceName == invitation.serviceName)
    #expect(throws: SecureLinkError.expired) { try PairingInvitation(code: code, now: now.addingTimeInterval(301)) }
    #expect(throws: SecureLinkError.invalidCode) { try PairingInvitation(code: String(repeating: "x", count: 2049)) }
    #expect(!String(describing: invitation).contains(code))
    #expect(String(reflecting: invitation.credential) == "LinkCredential(<redacted>)")
}

@Test(.timeLimit(.minutes(1))) @MainActor func 客户端保存失败会撤销服务端待确认凭据() async throws {
    let hostStore = MemoryCredentials(), clientStore = MemoryCredentials(); clientStore.failSave = true
    let invitation = try PairingInvitation(hostID: UUID())
    let host = try PairingHost(invitation: invitation, store: hostStore, loopbackOnly: true)
    var port: NWEndpoint.Port?, failed = false, clientFailed = false
    host.onReady = { port = $0 }; host.onFailure = { _ in failed = true }; host.start()
    defer { host.cancel() }; try await waitFor { port != nil }
    let client = try PairingClient(invitation: invitation, endpoint: .hostPort(host: "127.0.0.1", port: port!), store: clientStore)
    client.onFailure = { _ in clientFailed = true }; client.start(); defer { client.cancel() }
    try await waitFor { failed && clientFailed }
    #expect(hostStore.values.isEmpty && clientStore.values.isEmpty)
}

@Test(.timeLimit(.minutes(1))) @MainActor func 不同用途的同一密钥不能完成握手() async throws {
    let credential = try LinkCredential(hostID: UUID(), clientID: UUID())
    let listener = try CredentialListener(credential: credential, pairing: true, loopbackOnly: true)
    var port: NWEndpoint.Port?, accepted = false
    listener.onReady = { port = $0 }; listener.onAuthenticated = { accepted = true; $0.close() }
    listener.start(); defer { listener.stop() }; try await waitFor { port != nil }
    let wrong = TLSChannel(endpoint: .hostPort(host: "127.0.0.1", port: port!), credential: credential, pairing: false)
    var closed = false, ready = false
    wrong.onReady = { ready = true }; wrong.onClose = { _ in closed = true }; wrong.start()
    defer { wrong.close() }; try await waitFor { closed }
    #expect(!ready && !accepted)
}

@Test @MainActor func 过期邀请无法创建监听器且凭据拒绝同一身份() throws {
    let id = UUID(), store = MemoryCredentials()
    #expect(throws: SecureLinkError.invalidCredential) { try LinkCredential(hostID: id, clientID: id) }
    let old = try PairingInvitation(hostID: id, now: Date().addingTimeInterval(-301))
    #expect(throws: SecureLinkError.expired) { try PairingHost(invitation: old, store: store, loopbackOnly: true) }
}

@Test(arguments: [false, true]) @MainActor func 输出回调内撤销不会复活旧批次的按住(_ downFirst: Bool) {
    let down = LinkMessage.button(RemoteButton(id: "talk", phase: .down))
    let up = LinkMessage.button(RemoteButton(id: "talk", phase: .up))
    let move = LinkMessage.pointer(.move(x: 1, y: 1))
    var delivered: [LinkMessage] = [], output: LinkOutput!
    output = LinkOutput(onMessage: { message in
        delivered.append(message); output.cancel()
    }, onClose: {})
    output.apply(downFirst ? [.deliver(down), .deliver(up)] : [.deliver(move), .deliver(down)])
    #expect(delivered == (downFirst ? [down, .button(RemoteButton(id: "talk", phase: .cancel))] : [move]))
    output.apply([.deliver(down)]); output.cancel()
    #expect(delivered.count == (downFirst ? 2 : 1))
    output = nil
}

@Test(.timeLimit(.minutes(1)), arguments: ["cancel", "sendFailure", "deleteFailure"])
@MainActor func 配对完成窗口可取消且删除失败可重试(_ mode: String) async throws {
    let hs = MemoryCredentials(), cs = MemoryCredentials()
    hs.failRemove = mode == "deleteFailure"
    let host = try PairingHost(invitation: PairingInvitation(hostID: UUID()), store: hs, loopbackOnly: true)
    var port: NWEndpoint.Port?, paired = false, failure: SecureLinkError?, completion: (@MainActor @Sendable (Bool) -> Void)?
    host.onReady = { port = $0 }; host.onPaired = { _ in paired = true }; host.onFailure = { failure = $0 }
    host.confirmationSender = { _, done in completion = done }
    host.start(); defer { host.cancel() }; try await waitFor { port != nil }
    let client = try PairingClient(invitation: host.invitation, endpoint: .hostPort(host: "127.0.0.1", port: port!), store: cs)
    var clientFailed = false
    client.onFailure = { _ in clientFailed = true }; client.start(); defer { client.cancel() }
    try await waitFor { completion != nil }
    #expect(hs.values.count == 1)
    if mode == "cancel" { host.cancel(); completion?(true) }
    else { completion?(false) }
    try await waitFor { clientFailed && failure != nil }
    #expect(!paired && cs.values.isEmpty)
    if mode == "deleteFailure" {
        #expect(failure == .storage && host.cleanupRequired != nil && hs.values.count == 1)
        hs.failRemove = false; try host.retryCleanup()
        #expect(host.cleanupRequired == nil && hs.values.isEmpty)
    } else { #expect(hs.values.isEmpty && host.cleanupRequired == nil) }
}

@Test(.timeLimit(.minutes(1))) @MainActor func 客户端回滚失败返回可清理凭据编号() async throws {
    let hs = MemoryCredentials(), cs = MemoryCredentials(); hs.failSave = true; cs.failRemove = true
    let host = try PairingHost(invitation: PairingInvitation(hostID: UUID()), store: hs, loopbackOnly: true)
    var port: NWEndpoint.Port?, failure: SecureLinkError?
    host.onReady = { port = $0 }; host.start(); defer { host.cancel() }
    try await waitFor { port != nil }
    let client = try PairingClient(invitation: host.invitation, endpoint: .hostPort(host: "127.0.0.1", port: port!), store: cs)
    client.onFailure = { failure = $0 }; client.start(); defer { client.cancel() }
    try await waitFor { failure != nil }
    #expect(failure == .storage && client.cleanupRequired != nil && cs.values.count == 1)
    cs.failRemove = false; try client.retryCleanup()
    #expect(cs.values.isEmpty && client.cleanupRequired == nil)
}
