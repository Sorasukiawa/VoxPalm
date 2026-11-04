import Foundation
@preconcurrency import Network
import Security

enum TLSConfiguration {
    static func parameters(_ credential: LinkCredential, pairing: Bool) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_tls_resumption_enabled(options, false)
        sec_protocol_options_set_tls_tickets_enabled(options, false)
        sec_protocol_options_add_tls_application_protocol(options, pairing ? "voxpalm-pair-v1" : "voxpalm-link-v1")
        let identity = Data("voxpalm-v1:\(pairing ? "pair" : "link"):\(credential.id.uuidString)".utf8)
        let keyData = credential.secret.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityData = identity.withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(options, keyData as __DispatchData, identityData as __DispatchData)
        // 仅接受 PSK 认证；意外进入证书认证路径时失败，不跳过证书校验。
        sec_protocol_options_set_verify_block(options, { _, _, complete in complete(false) }, .main)
        let tcp = NWProtocolTCP.Options(); tcp.noDelay = true
        return NWParameters(tls: tls, tcp: tcp)
    }
}

/// 所有方法和回调都在主执行器；网络回调队列固定为 main。
@MainActor final class TLSChannel {
    let connection: NWConnection
    private let pairing: Bool
    private var closed = false
    private var ready = false
    private var started = false
    private var pendingBytes = 0
    private var deadline: Task<Void, Never>?
    var onReady: (() -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((SecureLinkError?) -> Void)?

    init(connection: NWConnection, pairing: Bool) { self.connection = connection; self.pairing = pairing }
    convenience init(endpoint: NWEndpoint, credential: LinkCredential, pairing: Bool) {
        self.init(connection: NWConnection(to: endpoint, using: TLSConfiguration.parameters(credential, pairing: pairing)), pairing: pairing)
    }
    deinit { connection.cancel(); deadline?.cancel() }
    func start() {
        guard !closed else { onClose?(.connection); onClose = nil; return }
        guard !started else { return }; started = true
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                switch state {
                case .ready:
                    guard let tls = self.connection.metadata(definition: NWProtocolTLS.definition) as? NWProtocolTLS.Metadata,
                          sec_protocol_metadata_get_negotiated_tls_protocol_version(tls.securityProtocolMetadata) == .TLSv12,
                          !sec_protocol_metadata_get_early_data_accepted(tls.securityProtocolMetadata),
                          sec_protocol_metadata_get_negotiated_tls_ciphersuite(tls.securityProtocolMetadata).rawValue == UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256),
                          let alpn = sec_protocol_metadata_get_negotiated_protocol(tls.securityProtocolMetadata),
                          String(cString: alpn) == (self.pairing ? "voxpalm-pair-v1" : "voxpalm-link-v1") else {
                        self.close(.protocolViolation); return
                    }
                    self.ready = true; self.deadline?.cancel(); self.deadline = nil
                    self.onReady?(); self.receive()
                case .failed, .waiting: self.close(.connection)
                case .cancelled: self.close(nil)
                default: break
                }
            }
        }
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            self?.close(.timeout)
        }
        connection.start(queue: .main)
    }
    func send(_ data: Data, completion: (@MainActor @Sendable (Bool) -> Void)? = nil) {
        guard !closed, ready else { completion?(false); return }
        guard data.count <= 65_540, pendingBytes + data.count <= 262_144 else {
            completion?(false); close(.backlog); return
        }
        pendingBytes += data.count
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            MainActor.assumeIsolated {
                guard let self else { completion?(false); return }
                self.pendingBytes -= data.count
                completion?(error == nil && !self.closed)
                if error != nil { self.close(.connection) }
            }
        })
    }
    private func receive() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, ended, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty { self.onData?(data) }
                if error != nil { self.close(.connection) }
                else if ended { self.close(nil) }
                else { self.receive() }
            }
        }
    }
    func close(_ error: SecureLinkError? = nil) {
        guard !closed else { return }; closed = true
        deadline?.cancel(); deadline = nil; connection.cancel()
        let callback = onClose; onReady = nil; onData = nil; onClose = nil
        callback?(error)
    }
}

/// 单凭据监听：避免把“某把密钥握手成功”误当成另一个设备的身份。
@MainActor final class CredentialListener {
    let listener: NWListener
    private let pairing: Bool
    private var channels: [UUID: TLSChannel] = [:]
    private var stopped = false
    var onReady: ((NWEndpoint.Port) -> Void)?
    var onAuthenticated: ((TLSChannel) -> Void)?
    var onFailure: (() -> Void)?
    init(credential: LinkCredential, pairing: Bool, loopbackOnly: Bool) throws {
        self.pairing = pairing
        let parameters = TLSConfiguration.parameters(credential, pairing: pairing)
        if loopbackOnly { parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any) }
        listener = try NWListener(using: parameters, on: .any)
        if !loopbackOnly {
            listener.service = NWListener.Service(name: credential.id.uuidString, type: pairing ? "_vp-pair._tcp" : "_voxpalm._tcp")
        }
    }
    deinit { listener.cancel() }
    func start() {
        guard !stopped else { return }
        listener.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, !self.stopped else { return }
                if case .ready = state, let port = self.listener.port { self.onReady?(port) }
                if case .failed = state { self.onFailure?(); self.stop() }
                if case .waiting = state { self.onFailure?(); self.stop() }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self, !self.stopped, self.channels.count < 4 else { connection.cancel(); return }
                let id = UUID(), channel = TLSChannel(connection: connection, pairing: self.pairing)
                self.channels[id] = channel
                channel.onClose = { [weak self] _ in self?.channels.removeValue(forKey: id) }
                channel.onReady = { [weak self, weak channel] in
                    guard let self, let channel else { return }
                    self.channels.removeValue(forKey: id)
                    if !self.stopped, let callback = self.onAuthenticated { callback(channel) }
                    else { channel.close() }
                }
                channel.start()
            }
        }
        listener.start(queue: .main)
    }
    func stop() {
        stopped = true
        listener.cancel()
        let pending = Array(channels.values); channels.removeAll()
        for channel in pending { channel.close() }
    }
}

/// 服务名是随机配对标识；候选地址必须再经 TLS 验证，发现结果不授予控制权。
@MainActor public final class LinkDiscovery {
    private var browser: NWBrowser?
    private var generation = UUID()
    public var onResults: (([NWEndpoint]) -> Void)?
    public var onUnavailable: (() -> Void)?
    public init() {}
    public func start(serviceID: UUID, pairing: Bool) {
        stop()
        let browser = NWBrowser(for: .bonjour(type: pairing ? "_vp-pair._tcp" : "_voxpalm._tcp", domain: nil), using: .tcp)
        self.browser = browser
        let generation = generation
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                self.onResults?(results.compactMap {
                    if case let .service(name, _, _, _) = $0.endpoint, name == serviceID.uuidString { return $0.endpoint }
                    return nil
                })
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, self.generation == generation else { return }
                switch state { case .failed, .waiting: self.onUnavailable?(); default: break }
            }
        }
        browser.start(queue: .main)
    }
    deinit { browser?.cancel() }
    public func stop() { generation = UUID(); browser?.cancel(); browser = nil }
}
