import Foundation
@preconcurrency import Network

/// 一个邀请只接受第一条通过 TLS 认证的连接；失败后需要本人重新生成邀请。
@MainActor public final class PairingHost {
    public let invitation: PairingInvitation
    private let store: any LinkCredentialStore
    private let listener: CredentialListener
    private var channel: TLSChannel?
    private var timer: Task<Void, Never>?
    private var consumed = false
    private var acknowledged = false
    var confirmationSender: ((Data, @escaping @MainActor @Sendable (Bool) -> Void) -> Void)?
    public private(set) var cleanupRequired: UUID?
    private var saved: UUID?
    private var input = Data()
    private var finished = false
    private let expires: ContinuousClock.Instant
    public var onReady: ((NWEndpoint.Port) -> Void)?
    public var onPaired: ((LinkCredential) -> Void)?
    public var onFailure: ((SecureLinkError) -> Void)?

    public init(invitation: PairingInvitation, store: any LinkCredentialStore, loopbackOnly: Bool = false) throws {
        guard invitation.expiresAt > .now else { throw SecureLinkError.expired }
        self.invitation = invitation; self.store = store
        expires = .now + .seconds(min(300, max(0, invitation.expiresAt.timeIntervalSinceNow)))
        listener = try CredentialListener(credential: invitation.credential, pairing: true, loopbackOnly: loopbackOnly)
    }
    public func start() {
        guard timer == nil, !finished else { return }
        listener.onReady = { [weak self] in self?.onReady?($0) }
        listener.onFailure = { [weak self] in self?.fail(.connection) }
        listener.onAuthenticated = { [weak self] in self?.accept($0) }
        let expires = expires
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: expires, clock: .continuous) } catch { return }
            self?.fail(.expired)
        }
        listener.start()
    }
    private func accept(_ channel: TLSChannel) {
        guard !consumed, !finished, ContinuousClock.now < expires else { channel.close(.consumed); return }
        consumed = true; self.channel = channel; listener.stop()
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.fail(.timeout)
        }
        do {
            let credential = try LinkCredential(hostID: invitation.credential.hostID, clientID: invitation.credential.clientID)
            channel.onClose = { [weak self] _ in self?.fail(.connection) }
            channel.onData = { [weak self, weak channel] bytes in
                guard let self, let channel, !self.finished else { return }
                guard !self.acknowledged else { self.fail(.protocolViolation); return }
                self.input.append(bytes)
                guard self.input.count <= 3 else { self.fail(.protocolViolation); return }
                guard self.input.count == 3 else { return }
                guard self.input == Data("ACK".utf8) else { self.fail(.protocolViolation); return }
                self.acknowledged = true
                do { try self.store.save(credential); self.saved = credential.id }
                catch { self.fail(.storage); return }
                let complete: @MainActor @Sendable (Bool) -> Void = { [weak self, weak channel] sent in
                    guard let self, !self.finished else { return }
                    guard sent else { self.fail(.connection); return }
                    self.finished = true; self.timer?.cancel(); self.timer = nil; self.saved = nil
                    self.onPaired?(credential); channel?.close()
                }
                if let sender = self.confirmationSender { sender(Data("DONE".utf8), complete) }
                else { channel.send(Data("DONE".utf8), completion: complete) }
            }
            let body = try credential.encoded()
            var framed = Data([UInt8(body.count >> 8), UInt8(body.count & 255)])
            framed.append(body); channel.send(framed)
        } catch { fail(.storage) }
    }
    private func fail(_ error: SecureLinkError) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil; listener.stop(); channel?.close(error); channel = nil
        var reported = error
        if let saved {
            do { try store.remove(id: saved) }
            catch { cleanupRequired = saved; reported = .storage }
            self.saved = nil
        }
        onFailure?(reported)
    }
    public func retryCleanup() throws {
        guard let id = cleanupRequired else { return }
        try store.remove(id: id); cleanupRequired = nil
    }
    public func cancel() { fail(.connection) }
}

@MainActor public final class PairingClient {
    private let invitation: PairingInvitation
    private let store: any LinkCredentialStore
    private let channel: TLSChannel
    private var timer: Task<Void, Never>?
    private var input = Data()
    private var pending: LinkCredential?
    private var finished = false
    public private(set) var cleanupRequired: UUID?
    public var onPaired: ((LinkCredential) -> Void)?
    public var onFailure: ((SecureLinkError) -> Void)?
    public init(invitation: PairingInvitation, endpoint: NWEndpoint, store: any LinkCredentialStore) throws {
        guard invitation.expiresAt > .now else { throw SecureLinkError.expired }
        self.invitation = invitation; self.store = store
        channel = TLSChannel(endpoint: endpoint, credential: invitation.credential, pairing: true)
    }
    public func start() {
        guard timer == nil, !finished else { return }
        channel.onData = { [weak self] in self?.receive($0) }
        channel.onClose = { [weak self] _ in self?.fail(.connection) }
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.fail(.timeout)
        }
        channel.start()
    }
    private func receive(_ data: Data) {
        guard !finished, input.count + data.count <= 1026 else { fail(.protocolViolation); return }
        input.append(data)
        if let pending {
            guard input.count <= 4 else { fail(.protocolViolation); return }
            if input.count == 4 {
                guard input == Data("DONE".utf8) else { fail(.protocolViolation); return }
                finished = true; timer?.cancel(); timer = nil; self.pending = nil
                onPaired?(pending); channel.close()
            }
            return
        }
        guard input.count >= 2 else { return }
        let count = Int(input[0]) * 256 + Int(input[1])
        guard count > 0, count <= 1024, input.count <= count + 2 else { fail(.protocolViolation); return }
        guard input.count == count + 2 else { return }
        do {
            let credential = try LinkCredential.decode(Data(input.dropFirst(2)))
            guard credential.hostID == invitation.credential.hostID, credential.clientID == invitation.credential.clientID,
                  credential.id != invitation.credential.id, credential.secret != invitation.credential.secret else {
                fail(.protocolViolation); return
            }
            try store.save(credential); pending = credential; input.removeAll()
            channel.send(Data("ACK".utf8))
        } catch { fail(.storage) }
    }
    private func fail(_ error: SecureLinkError) {
        guard !finished else { return }; finished = true
        timer?.cancel(); timer = nil; channel.close(error)
        var reported = error
        if let pending {
            do { try store.remove(id: pending.id) }
            catch { cleanupRequired = pending.id; reported = .storage }
            self.pending = nil
        }
        onFailure?(reported)
    }
    public func retryCleanup() throws {
        guard let id = cleanupRequired else { return }
        try store.remove(id: id); cleanupRequired = nil
    }
    public func cancel() { fail(.connection) }
}
