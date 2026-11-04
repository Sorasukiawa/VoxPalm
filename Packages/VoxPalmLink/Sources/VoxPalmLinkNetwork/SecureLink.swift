import Foundation
@preconcurrency import Network
import VoxPalmLink

@MainActor public final class SecureLinkHost {
    private let credential: LinkCredential
    private let store: any LinkCredentialStore
    private let listener: CredentialListener
    private var channel: TLSChannel?
    private var output: LinkOutput?
    private var session = LinkSession()
    private var binding: LinkConnection?
    private var timer: Task<Void, Never>?
    private var stopped = false
    public var onReady: ((NWEndpoint.Port) -> Void)?
    public var onConnected: (() -> Void)?
    public var onUnavailable: (() -> Void)?
    public var onMessage: ((LinkMessage) -> Void)?
    public var onDisconnected: (() -> Void)?
    public init(credential: LinkCredential, store: any LinkCredentialStore, loopbackOnly: Bool = false) throws {
        self.credential = credential; self.store = store
        listener = try CredentialListener(credential: credential, pairing: false, loopbackOnly: loopbackOnly)
        try session.requestPairing(peer: credential.clientID); try session.confirmPairing(peer: credential.clientID)
    }
    public func start() {
        guard !stopped, timer == nil else { return }
        listener.onReady = { [weak self] in self?.onReady?($0) }
        listener.onAuthenticated = { [weak self] in self?.accept($0) }
        listener.onFailure = { [weak self] in self?.stop(); self?.onUnavailable?() }
        listener.start()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self else { return }
                self.output?.apply(self.session.checkTimeout())
            }
        }
    }
    private func accept(_ incoming: TLSChannel) {
        guard !stopped, channel == nil else { incoming.close(.connection); return }
        do {
            // 每个监听器只配置当前凭据的一把 PSK，身份不从远端包头推断。
            guard let stored = try store.load(id: credential.id), stored.secret == credential.secret,
                  stored.hostID == credential.hostID, stored.clientID == credential.clientID else {
                incoming.close(.invalidCredential); return
            }
            let binding = try session.connectAuthenticated(peer: credential.clientID)
            self.binding = binding; channel = incoming
            output = LinkOutput(onMessage: { [weak self] in self?.onMessage?($0) },
                                onClose: { [weak incoming] in incoming?.close(.protocolViolation) })
            incoming.onData = { [weak self] bytes in
                guard let self, self.binding == binding else { return }
                self.output?.apply(self.session.receive(bytes, from: binding.transportID))
            }
            incoming.onClose = { [weak self] _ in
                guard let self, self.binding == binding else { return }
                _ = self.session.disconnected(binding.transportID)
                self.binding = nil; self.channel = nil
                let oldOutput = self.output; self.output = nil
                oldOutput?.cancel(); self.onDisconnected?()
            }
            incoming.send(Data(("VPL1" + binding.sessionID.uuidString).utf8))
            onConnected?()
        } catch { incoming.close(.invalidCredential) }
    }
    public func stop() {
        guard !stopped else { return }; stopped = true
        timer?.cancel(); timer = nil; listener.stop()
        if let binding { _ = session.disconnected(binding.transportID) }
        binding = nil; let old = channel; channel = nil
        let oldOutput = output; output = nil; oldOutput?.cancel(); old?.close()
    }
    /// 先停止当前连接，即使钥匙串暂时不可写也不能继续控制；删除失败明确返回给 UI。
    public func revoke() throws {
        stop(); _ = session.revoke()
        try store.remove(id: credential.id)
    }
}

@MainActor public final class SecureLinkClient {
    private let credential: LinkCredential
    private let channel: TLSChannel
    private var sessionID: UUID?
    private var sequence: UInt64 = 0
    private var greeting = Data()
    private var timer: Task<Void, Never>?
    private var started = false
    private var closed = false
    public var onReady: (() -> Void)?
    public var onDisconnected: ((SecureLinkError?) -> Void)?
    public init(credential: LinkCredential, endpoint: NWEndpoint) {
        self.credential = credential
        channel = TLSChannel(endpoint: endpoint, credential: credential, pairing: false)
    }
    public func start() {
        guard !started else { return }; started = true
        channel.onClose = { [weak self] error in
            guard let self, !self.closed else { return }; self.closed = true
            self.timer?.cancel(); self.timer = nil; self.sessionID = nil
            self.onDisconnected?(error)
        }
        channel.onData = { [weak self] data in
            guard let self, self.sessionID == nil, self.greeting.count + data.count <= 40 else {
                self?.channel.close(.protocolViolation); return
            }
            self.greeting.append(data)
            guard self.greeting.count == 40 else { return }
            guard self.greeting.prefix(4) == Data("VPL1".utf8),
                  let text = String(data: self.greeting.dropFirst(4), encoding: .utf8), let id = UUID(uuidString: text) else {
                self.channel.close(.protocolViolation); return
            }
            self.sessionID = id; self.greeting.removeAll(); self.timer?.cancel()
            self.timer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(3)) } catch { return }
                    guard let self else { return }
                    do { try self.send(.heartbeat) } catch { self.channel.close(.connection) }
                }
            }
            self.onReady?()
        }
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.channel.close(.timeout)
        }
        channel.start()
    }
    public func send(_ message: LinkMessage) throws {
        guard !closed, let sessionID, sequence < UInt64.max else { throw SecureLinkError.connection }
        let next = sequence + 1
        let bytes = try LinkCodec.frame(LinkEnvelope(deviceID: credential.clientID, sessionID: sessionID, sequence: next, message: message))
        sequence = next; channel.send(bytes)
    }
    public func stop() { channel.close() }
}
