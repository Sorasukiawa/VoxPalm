import Foundation
import Testing
@testable import VoxPalmLink

private struct Fixture {
    let peer = UUID()
    let now = ContinuousClock.now
    var receiver = LinkSession()
    var connection: LinkConnection
    var next: UInt64 = 1

    init() throws {
        try receiver.requestPairing(peer: peer); try receiver.confirmPairing(peer: peer)
        connection = try receiver.connectAuthenticated(peer: peer, now: now)
    }

    func body(_ message: LinkMessage, sequence: UInt64? = nil, peer: UUID? = nil, session: UUID? = nil) throws -> Data {
        try LinkCodec.frame(LinkEnvelope(deviceID: peer ?? self.peer, sessionID: session ?? connection.sessionID,
                                         sequence: sequence ?? next, message: message))
    }

    mutating func send(_ message: LinkMessage) throws -> [LinkEffect] {
        let bytes = try body(message); next += 1
        return receiver.receive(bytes, from: connection.transportID, now: now)
    }
}

@Test func 未确认和错误对端不能建立连接() throws {
    var receiver = LinkSession(); let peer = UUID()
    #expect(throws: LinkError.untrustedPeer) { try receiver.connectAuthenticated(peer: peer) }
    try receiver.requestPairing(peer: peer)
    #expect(throws: LinkError.untrustedPeer) { try receiver.connectAuthenticated(peer: peer) }
    #expect(throws: LinkError.invalidTransition) { try receiver.confirmPairing(peer: UUID()) }
    #expect(receiver.state == .awaitingConfirmation(peer: peer))
    try receiver.cancelPairing(); #expect(receiver.state == .unpaired)
    try receiver.requestPairing(peer: peer); try receiver.confirmPairing(peer: peer)
    #expect(throws: LinkError.wrongPeer) { try receiver.connectAuthenticated(peer: UUID()) }
    _ = try receiver.connectAuthenticated(peer: peer)
    #expect(throws: LinkError.untrustedPeer) { try receiver.connectAuthenticated(peer: peer) }
}

@Test func 正常按键和指针只输出对应意图() throws {
    var f = try Fixture()
    for message in [LinkMessage.button(RemoteButton(id: "talk", phase: .down)),
                    .pointer(.move(x: 12, y: -4)), .pointer(.button(.primary, .down)),
                    .pointer(.scroll(x: 0, y: 8)), .pointer(.button(.primary, .up)),
                    .button(RemoteButton(id: "talk", phase: .up))] {
        #expect(try f.send(message) == [.deliver(message)])
    }
    #expect(f.receiver.disconnected(f.connection.transportID).isEmpty)
}

@Test func 断线只取消按住和录音不补发松开或结束() throws {
    var f = try Fixture(); let audio = UUID()
    _ = try f.send(.button(RemoteButton(id: "talk", phase: .down)))
    _ = try f.send(.pointer(.button(.primary, .down)))
    _ = try f.send(.audioStart(id: audio, format: PCMFormat(sampleRate: 16_000)))
    let effects = f.receiver.disconnected(f.connection.transportID)
    #expect(effects == [.deliver(.button(RemoteButton(id: "talk", phase: .cancel))),
                        .deliver(.pointer(.button(.primary, .cancel))), .deliver(.audioCancel(id: audio))])
    #expect(f.receiver.state == .reconnecting(peer: f.peer))
    #expect(f.receiver.disconnected(f.connection.transportID).isEmpty)
}

@Test func 旧连接的消息断线和错误不能影响重连() throws {
    var f = try Fixture()
    let old = f.connection, bytes = try f.body(.button(RemoteButton(id: "talk", phase: .down)))
    _ = f.receiver.disconnected(old.transportID)
    f.connection = try f.receiver.connectAuthenticated(peer: f.peer, now: f.now)
    #expect(old.sessionID != f.connection.sessionID && old.transportID != f.connection.transportID)
    #expect(f.receiver.receive(bytes, from: old.transportID, now: f.now).isEmpty)
    #expect(f.receiver.disconnected(old.transportID).isEmpty)
    #expect(f.receiver.transportFailed(old.transportID).isEmpty)
    let down = LinkMessage.button(RemoteButton(id: "talk", phase: .down))
    #expect(try f.send(down) == [.deliver(down)])
}

@Test(arguments: ["replay", "gap", "peer", "session", "truncated"])
func 无效消息关闭当前连接并取消已有按住(_ kind: String) throws {
    var f = try Fixture()
    _ = try f.send(.button(RemoteButton(id: "talk", phase: .down)))
    let bytes: Data
    let error: LinkError
    switch kind {
    case "replay": bytes = try f.body(.heartbeat, sequence: 1); error = .replayedMessage
    case "gap": bytes = try f.body(.heartbeat, sequence: 3); error = .sequenceGap
    case "peer": bytes = try f.body(.heartbeat, peer: UUID()); error = .wrongPeer
    case "session": bytes = try f.body(.heartbeat, session: UUID()); error = .wrongSession
    default: bytes = Data([0, 0, 0, 1, 0]); error = .truncated
    }
    #expect(f.receiver.receive(bytes, from: f.connection.transportID, now: f.now) == [
        .deliver(.button(RemoteButton(id: "talk", phase: .cancel))),
        .closeTransport(f.connection.transportID, reason: error)
    ])
}

@Test func 撤销立即释放且必须重新确认() throws {
    var f = try Fixture()
    _ = try f.send(.pointer(.button(.secondary, .down)))
    #expect(f.receiver.revoke() == [.deliver(.pointer(.button(.secondary, .cancel))),
                                   .closeTransport(f.connection.transportID, reason: .untrustedPeer)])
    #expect(f.receiver.state == .revoked(peer: f.peer))
    #expect(throws: LinkError.untrustedPeer) { try f.receiver.connectAuthenticated(peer: f.peer) }
    #expect(f.receiver.revoke().isEmpty)
    try f.receiver.requestPairing(peer: f.peer); try f.receiver.confirmPairing(peer: f.peer)
    _ = try f.receiver.connectAuthenticated(peer: f.peer)
}

@Test func 心跳续期而过期后收到消息也不能恢复旧连接() throws {
    var f = try Fixture()
    let bytes = try f.body(.heartbeat)
    #expect(f.receiver.receive(bytes, from: f.connection.transportID, now: f.now + .seconds(9)).isEmpty)
    #expect(f.receiver.checkTimeout(now: f.now + .seconds(18)).isEmpty)
    #expect(f.receiver.checkTimeout(now: f.now + .seconds(19)) == [.closeTransport(f.connection.transportID, reason: .idleTimeout)])
    var late = try Fixture()
    let lateBytes = try late.body(.button(RemoteButton(id: "talk", phase: .down)))
    #expect(late.receiver.receive(lateBytes, from: late.connection.transportID, now: late.now + .seconds(10)) == [
        .closeTransport(late.connection.transportID, reason: .idleTimeout)
    ])
}

@Test func 重复按下无对应松开和按住数量上限会关闭连接() throws {
    var duplicate = try Fixture()
    _ = try duplicate.send(.button(RemoteButton(id: "a", phase: .down)))
    #expect(try duplicate.send(.button(RemoteButton(id: "a", phase: .down))).last ==
            .closeTransport(duplicate.connection.transportID, reason: .invalidEventOrder))
    var missing = try Fixture()
    #expect(try missing.send(.pointer(.button(.middle, .up))).last ==
            .closeTransport(missing.connection.transportID, reason: .invalidEventOrder))
    var many = try Fixture()
    for i in 0..<LinkLimits.maximumHeldButtons { _ = try many.send(.button(RemoteButton(id: "k\(i)", phase: .down))) }
    let effects = try many.send(.button(RemoteButton(id: "too-many", phase: .down)))
    #expect(effects.count == LinkLimits.maximumHeldButtons + 1)
    #expect(effects.last == .closeTransport(many.connection.transportID, reason: .resourceLimit))
}

@Test(arguments: [UInt32(16_000), UInt32(48_000)]) func 正常PCM会话检查块序号和结束数量(_ rate: UInt32) throws {
    var f = try Fixture(); let id = UUID()
    let start = LinkMessage.audioStart(id: id, format: PCMFormat(sampleRate: rate))
    let chunk = LinkMessage.audioChunk(id: id, index: 0, pcm: Data(repeating: 0x12, count: Int(rate) * 2 / 25))
    #expect(try f.send(start) == [.deliver(start)])
    #expect(try f.send(chunk) == [.deliver(chunk)])
    #expect(try f.send(.audioEnd(id: id, chunkCount: 1)) == [.deliver(.audioEnd(id: id, chunkCount: 1))])
    #expect(f.receiver.disconnected(f.connection.transportID).isEmpty)
}

@Test(arguments: ["chunkGap", "tailGap", "wrongID", "tooLong", "restart"])
func 音频缺口或格式超限取消本轮不交付不完整结束(_ kind: String) throws {
    var f = try Fixture(); let id = UUID()
    _ = try f.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
    let invalid: LinkMessage
    switch kind {
    case "chunkGap": invalid = .audioChunk(id: id, index: 1, pcm: Data([0, 0]))
    case "tailGap": invalid = .audioEnd(id: id, chunkCount: 1)
    case "wrongID": invalid = .audioCancel(id: UUID())
    case "tooLong": invalid = .audioChunk(id: id, index: 0, pcm: Data(count: 1282))
    default: invalid = .audioStart(id: UUID(), format: PCMFormat(sampleRate: 16_000))
    }
    let effects = try f.send(invalid)
    #expect(effects.count == 2 && effects.first == .deliver(.audioCancel(id: id)))
    #expect(!effects.contains(.deliver(invalid)))
    #expect(f.receiver.state == .reconnecting(peer: f.peer))
}

@Test func 五分钟音频预算无需真实等待且完成后不保存声音() throws {
    var f = try Fixture(); let id = UUID()
    _ = try f.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
    let pcm = Data(count: 1280)
    for i in 0..<7500 {
        let chunk = LinkMessage.audioChunk(id: id, index: UInt32(i), pcm: pcm)
        #expect(try f.send(chunk) == [.deliver(chunk)])
    }
    #expect(try f.send(.audioChunk(id: id, index: 7500, pcm: Data([0, 0]))) == [
        .deliver(.audioCancel(id: id)), .closeTransport(f.connection.transportID, reason: .resourceLimit)
    ])
}

@Test func 录音ID不能复用且每连接录音数量有界() throws {
    var reused = try Fixture(); let id = UUID()
    _ = try reused.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
    _ = try reused.send(.audioCancel(id: id))
    #expect(try reused.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000))).last ==
            .closeTransport(reused.connection.transportID, reason: .invalidEventOrder))
    var many = try Fixture()
    for _ in 0..<LinkLimits.maximumAudioSessions {
        let id = UUID()
        _ = try many.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
        _ = try many.send(.audioEnd(id: id, chunkCount: 0))
    }
    #expect(try many.send(.audioStart(id: UUID(), format: PCMFormat(sampleRate: 16_000))).last ==
            .closeTransport(many.connection.transportID, reason: .resourceLimit))
}

@Test func 流式接收自动处理分片合并和分帧错误() throws {
    var f = try Fixture()
    let down = LinkMessage.button(RemoteButton(id: "talk", phase: .down))
    let first = try f.body(down, sequence: 1)
    let second = try f.body(.heartbeat, sequence: 2)
    #expect(f.receiver.receive(first.prefix(3), from: f.connection.transportID, now: f.now).isEmpty)
    #expect(f.receiver.receive(first.dropFirst(3) + second, from: f.connection.transportID, now: f.now) == [.deliver(down)])
    #expect(f.receiver.receive(Data([255, 255, 255, 255]), from: f.connection.transportID, now: f.now) == [
        .deliver(.button(RemoteButton(id: "talk", phase: .cancel))),
        .closeTransport(f.connection.transportID, reason: .oversized)
    ])
}

@Test func 同批后续坏消息取消先前已输出的按住且半帧断线也取消() throws {
    var f = try Fixture()
    let down = LinkMessage.button(RemoteButton(id: "talk", phase: .down))
    let combined = try f.body(down, sequence: 1) + f.body(.heartbeat, sequence: 3)
    #expect(f.receiver.receive(combined, from: f.connection.transportID, now: f.now) == [
        .deliver(down), .deliver(.button(RemoteButton(id: "talk", phase: .cancel))),
        .closeTransport(f.connection.transportID, reason: .sequenceGap)
    ])
    var partial = try Fixture(); _ = try partial.send(down)
    _ = partial.receiver.receive(Data([0]), from: partial.connection.transportID, now: partial.now)
    #expect(partial.receiver.disconnected(partial.connection.transportID) == [
        .deliver(.button(RemoteButton(id: "talk", phase: .cancel))),
        .closeTransport(partial.connection.transportID, reason: .truncated)
    ])
}

@Test func 不完整消息不能续期且持续心跳也不能无限录音() throws {
    var partial = try Fixture()
    _ = partial.receiver.receive(Data([0]), from: partial.connection.transportID, now: partial.now + .seconds(9))
    #expect(partial.receiver.checkTimeout(now: partial.now + .seconds(10)) == [
        .closeTransport(partial.connection.transportID, reason: .idleTimeout)
    ])
    var f = try Fixture(); let id = UUID()
    _ = try f.send(.audioStart(id: id, format: PCMFormat(sampleRate: 16_000)))
    for second in stride(from: 5, through: 295, by: 5) {
        let bytes = try f.body(.heartbeat); f.next += 1
        #expect(f.receiver.receive(bytes, from: f.connection.transportID, now: f.now + .seconds(second)).isEmpty)
    }
    #expect(f.receiver.checkTimeout(now: f.now + .seconds(300)) == [
        .deliver(.audioCancel(id: id)), .closeTransport(f.connection.transportID, reason: .resourceLimit)
    ])
}
