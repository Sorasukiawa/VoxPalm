import Foundation

public enum LinkState: Sendable, Equatable {
    case unpaired
    case awaitingConfirmation(peer: UUID)
    case paired(peer: UUID)
    case connected(peer: UUID, session: UUID, transport: UUID)
    case reconnecting(peer: UUID)
    case revoked(peer: UUID)
}

/// 调用方执行这些效果；本包不会发系统按键、保存声音或访问网络。
public enum LinkEffect: Sendable, Equatable {
    case deliver(LinkMessage)
    case closeTransport(UUID, reason: LinkError)
}

public struct LinkConnection: Sendable, Equatable {
    public let sessionID: UUID
    public let transportID: UUID
}

/// 单个受信任对端的接收状态。调用方串行持有，每个真实连接使用新的 transportID 和 framer。
/// request/confirm/connect 是本地控制面 API，绝不能根据未认证的网络消息直接调用。
public struct LinkSession: Sendable {
    public private(set) var state: LinkState = .unpaired
    private var framer = LinkFramer()
    private var lastSequence: UInt64 = 0
    private var lastReceived: ContinuousClock.Instant?
    private var heldButtons: Set<String> = []
    private var heldPointerButtons: Set<PointerButton> = []
    private var audio: AudioState?
    private var usedAudioIDs: Set<UUID> = []

    private struct AudioState: Sendable {
        let id: UUID
        let format: PCMFormat
        let startedAt: ContinuousClock.Instant
        var chunks: UInt32 = 0
        var frames: UInt64 = 0
    }

    public init() {}

    public mutating func requestPairing(peer: UUID) throws {
        switch state {
        case .unpaired, .revoked: state = .awaitingConfirmation(peer: peer)
        default: throw LinkError.invalidTransition
        }
    }

    /// 这里只记录经过本机确认的信任结果，不验证配对码或建立密钥。
    public mutating func confirmPairing(peer: UUID) throws {
        guard state == .awaitingConfirmation(peer: peer) else { throw LinkError.invalidTransition }
        state = .paired(peer: peer)
    }

    public mutating func cancelPairing() throws {
        guard case .awaitingConfirmation = state else { throw LinkError.invalidTransition }
        state = .unpaired
    }

    /// peer 必须来自已验证的传输身份，不可直接取包头 deviceID。返回新会话 ID，供握手绑定。
    /// 不允许替换仍在线的连接；先显式断开旧 transport，撤销后必须重新走本机确认。
    /// 两种标识都由本层新建，调用方把 transportID 绑定到本次真实连接的回调。
    public mutating func connectAuthenticated(peer: UUID,
                                              now: ContinuousClock.Instant = .now) throws -> LinkConnection {
        let trusted: UUID
        switch state {
        case let .paired(peer), let .reconnecting(peer): trusted = peer
        default: throw LinkError.untrustedPeer
        }
        guard trusted == peer else { throw LinkError.wrongPeer }
        let session = UUID(), transport = UUID()
        state = .connected(peer: peer, session: session, transport: transport)
        framer = LinkFramer()
        lastSequence = 0; lastReceived = now; usedAudioIDs.removeAll()
        return LinkConnection(sessionID: session, transportID: transport)
    }

    /// 直接接收有长度前缀的流片段（每次最多 16 KiB）；拆帧和错误收尾不可分开遗漏。
    /// 同批前面的合法意图可先输出，后续错误会追加 cancel；调用方必须按顺序执行效果。
    public mutating func receive(_ bytes: Data, from transport: UUID,
                                 now: ContinuousClock.Instant = .now) -> [LinkEffect] {
        guard case let .connected(_, _, activeTransport) = state, activeTransport == transport else {
            return [] // 已失效连接的迟到数据不能操作或取消新连接。
        }
        var effects: [LinkEffect] = []
        do {
            try checkDeadline(now: now)
            for body in try framer.append(bytes) {
                let envelope = try LinkCodec.decode(body)
                try applyEnvelope(envelope, now: now)
                let message = envelope.message
                if message != .heartbeat { effects.append(.deliver(message)) }
            }
            return effects
        } catch {
            effects += terminate(reason: error as? LinkError ?? .invalidPayload)
            return effects
        }
    }

    private mutating func applyEnvelope(_ envelope: LinkEnvelope, now: ContinuousClock.Instant) throws {
        guard case let .connected(peer, session, _) = state else { throw LinkError.invalidTransition }
        guard envelope.deviceID == peer else { throw LinkError.wrongPeer }
        guard envelope.sessionID == session else { throw LinkError.wrongSession }
        guard envelope.sequence > lastSequence else { throw LinkError.replayedMessage }
        guard lastSequence < UInt64.max else { throw LinkError.sequenceExhausted }
        guard envelope.sequence == lastSequence + 1 else { throw LinkError.sequenceGap }
        try apply(envelope.message, now: now)
        lastSequence = envelope.sequence; lastReceived = now
    }

    private func checkDeadline(now: ContinuousClock.Instant) throws {
        if let lastReceived, now < lastReceived { throw LinkError.invalidPayload }
        if let lastReceived, now - lastReceived >= LinkLimits.idleTimeout { throw LinkError.idleTimeout }
        if let audio, now - audio.startedAt >= .seconds(LinkLimits.maximumRecordingSeconds) { throw LinkError.resourceLimit }
    }

    /// framer 出错、TLS 错误等也要走这里；不得只丢字节而遗留按住状态。
    public mutating func transportFailed(_ transport: UUID, reason: LinkError = .invalidPayload) -> [LinkEffect] {
        guard case let .connected(_, _, current) = state, current == transport else { return [] }
        return terminate(reason: reason)
    }

    public mutating func disconnected(_ transport: UUID) -> [LinkEffect] {
        guard case let .connected(peer, _, current) = state, current == transport else { return [] }
        do { try framer.finish() }
        catch { return terminate(reason: error as? LinkError ?? .invalidPayload) }
        let effects = cancelActiveInput()
        state = .reconnecting(peer: peer); lastReceived = nil
        return effects
    }

    public mutating func checkTimeout(now: ContinuousClock.Instant = .now) -> [LinkEffect] {
        guard case .connected = state else { return [] }
        do { try checkDeadline(now: now); return [] }
        catch { return terminate(reason: error as? LinkError ?? .invalidPayload) }
    }

    /// 调用方还必须同时从自己的可信设备存储撤销对端；本状态只负责当前连接和输入收尾。
    public mutating func revoke() -> [LinkEffect] {
        let peer: UUID
        var effects: [LinkEffect] = []
        switch state {
        case .unpaired: return []
        case let .awaitingConfirmation(id), let .paired(id), let .reconnecting(id), let .revoked(id): peer = id
        case let .connected(id, _, transport):
            peer = id; effects = cancelActiveInput()
            effects.append(.closeTransport(transport, reason: .untrustedPeer))
        }
        state = .revoked(peer: peer); lastReceived = nil; usedAudioIDs.removeAll()
        return effects
    }

    private mutating func apply(_ message: LinkMessage, now: ContinuousClock.Instant) throws {
        switch message {
        case .heartbeat: break
        case let .button(button):
            switch button.phase {
            case .down:
                guard !heldButtons.contains(button.id) else { throw LinkError.invalidEventOrder }
                guard heldButtons.count < LinkLimits.maximumHeldButtons else { throw LinkError.resourceLimit }
                heldButtons.insert(button.id)
            case .up, .cancel:
                guard heldButtons.remove(button.id) != nil else { throw LinkError.invalidEventOrder }
            }
        case let .pointer(.button(button, phase)):
            switch phase {
            case .down:
                guard heldPointerButtons.insert(button).inserted else { throw LinkError.invalidEventOrder }
            case .up, .cancel:
                guard heldPointerButtons.remove(button) != nil else { throw LinkError.invalidEventOrder }
            }
        case .pointer: break
        case let .audioStart(id, format):
            guard audio == nil, !usedAudioIDs.contains(id) else { throw LinkError.invalidEventOrder }
            guard usedAudioIDs.count < LinkLimits.maximumAudioSessions else { throw LinkError.resourceLimit }
            usedAudioIDs.insert(id); audio = AudioState(id: id, format: format, startedAt: now)
        case let .audioChunk(id, index, pcm):
            guard var current = audio, current.id == id else { throw LinkError.invalidEventOrder }
            guard index == current.chunks else { throw LinkError.audioDiscontinuity }
            let frames = UInt64(pcm.count / 2)
            guard frames <= UInt64(current.format.sampleRate) * 40 / 1000 else { throw LinkError.invalidPayload }
            guard current.frames + frames <= UInt64(current.format.sampleRate) * UInt64(LinkLimits.maximumRecordingSeconds),
                  current.chunks < UInt32.max else { throw LinkError.resourceLimit }
            current.frames += frames; current.chunks += 1; audio = current
        case let .audioEnd(id, count):
            guard let current = audio, current.id == id else { throw LinkError.invalidEventOrder }
            guard count == current.chunks else { throw LinkError.audioDiscontinuity }
            audio = nil
        case let .audioCancel(id):
            guard audio?.id == id else { throw LinkError.invalidEventOrder }
            audio = nil
        }
    }

    private mutating func terminate(reason: LinkError) -> [LinkEffect] {
        guard case let .connected(peer, _, transport) = state else { return [] }
        var effects = cancelActiveInput()
        effects.append(.closeTransport(transport, reason: reason))
        state = .reconnecting(peer: peer); lastReceived = nil
        return effects
    }

    private mutating func cancelActiveInput() -> [LinkEffect] {
        var effects = heldButtons.sorted().map { LinkEffect.deliver(.button(RemoteButton(id: $0, phase: .cancel))) }
        effects += heldPointerButtons.sorted { $0.rawValue < $1.rawValue }.map { .deliver(.pointer(.button($0, .cancel))) }
        if let audio { effects.append(.deliver(.audioCancel(id: audio.id))) }
        heldButtons.removeAll(); heldPointerButtons.removeAll(); audio = nil
        framer = LinkFramer()
        return effects
    }
}
