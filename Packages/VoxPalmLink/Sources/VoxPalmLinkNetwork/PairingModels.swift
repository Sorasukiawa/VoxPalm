import Combine
import Foundation
@preconcurrency import Network
import VoxPalmLink

public extension SecureLinkError {
    var userMessage: String {
        switch self {
        case .expired: return "配对码已过期，请在 Mac 上生成新的二维码。"
        case .invalidCode, .invalidCredential: return "配对码无效，请重新扫码或完整粘贴。"
        case .storage: return "设备记录或钥匙串暂时不可用。待清理的记录可点击撤销重试；请勿删除原文件。"
        case .consumed: return "这个配对码已经使用，请在 Mac 上重新生成。"
        default: return "未能连接。请确认两端在同一网络，并在系统设置的隐私与安全性中允许掌声访问本地网络，然后重试。"
        }
    }
}

/// UI 只消费固定状态文本和数字，不记录配对码、密钥或远端消息正文。
@MainActor public final class HostPairingModel: ObservableObject {
    @Published public private(set) var devices: [LinkDeviceRecord]
    @Published public private(set) var enabled = false
    @Published public private(set) var code: String?
    @Published public private(set) var expiresAt: Date?
    @Published public private(set) var message = "开启后，已配对的手机可以连接这台 Mac。"
    @Published public private(set) var states: [UUID: String] = [:]
    @Published public private(set) var testCount = 0
    private let store: LinkDeviceStore
    private let loopbackOnly: Bool
    private var pairing: PairingHost?
    private var hosts: [UUID: SecureLinkHost] = [:]
    private var generation = UUID()
    // 仅供回环测试选择动态端口，不经过 UI 或日志。
    var pairingPort: NWEndpoint.Port?
    var ports: [UUID: NWEndpoint.Port] = [:]

    public init(store: LinkDeviceStore, loopbackOnly: Bool = false) {
        self.store = store; self.loopbackOnly = loopbackOnly; devices = store.devices
    }
    public func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value
        if value {
            message = "等待已配对的手机连接。"
            for device in devices where device.state == .paired { startHost(device.id) }
        } else {
            generation = UUID(); cancelPairing()
            let old = Array(hosts.values); hosts.removeAll(); states.removeAll(); ports.removeAll()
            old.forEach { $0.stop() }; message = "手机连接已关闭。"
        }
    }
    public func beginPairing() {
        guard enabled else { return }
        cancelPairing()
        guard devices.count < 32 else { message = "设备记录已满，请先撤销不用的设备。"; return }
        do {
            let invitation = try PairingInvitation(hostID: store.identity)
            let host = try PairingHost(invitation: invitation, store: store, loopbackOnly: loopbackOnly)
            pairing = host; let token = generation
            message = "正在准备配对…"
            host.onReady = { [weak self, weak host] port in
                guard let self, let host, self.generation == token, self.pairing === host else { return }
                self.pairingPort = port; self.code = try? invitation.pairingCode(); self.expiresAt = invitation.expiresAt
                self.message = "用手机里的掌声扫描二维码。"
            }
            host.onPaired = { [weak self, weak host] credential in
                guard let self, let host, self.generation == token, self.pairing === host else { return }
                self.clearInvitation()
                do {
                    try self.store.activate(id: credential.id); self.devices = self.store.devices
                    self.message = "手机已配对，可在手机上点击连接。"; self.startHost(credential.id)
                } catch { self.rollback(credential.id) }
            }
            host.onFailure = { [weak self, weak host] error in
                guard let self, let host, self.pairing === host else { return }
                self.clearInvitation(); self.devices = self.store.devices; self.message = error.userMessage
            }
            host.start()
        } catch { message = SecureLinkError.connection.userMessage }
    }
    private func clearInvitation() { pairing = nil; code = nil; expiresAt = nil; pairingPort = nil }
    public func cancelPairing() {
        let old = pairing; clearInvitation(); old?.cancel(); devices = store.devices
    }
    private func rollback(_ id: UUID) {
        do { try store.remove(id: id) } catch { /* 目录保留待清理记录，用户可重试。 */ }
        devices = store.devices; message = SecureLinkError.storage.userMessage
    }
    private func startHost(_ id: UUID) {
        guard enabled, hosts[id] == nil else { return }
        do {
            guard let credential = try store.load(id: id), credential.hostID == store.identity else { throw SecureLinkError.storage }
            let host = try SecureLinkHost(credential: credential, store: store, loopbackOnly: loopbackOnly)
            hosts[id] = host; states[id] = "正在开启"; let token = generation
            host.onReady = { [weak self, weak host] port in
                guard let self, let host, self.generation == token, self.hosts[id] === host else { return }
                self.ports[id] = port; self.states[id] = "等待连接"
            }
            host.onConnected = { [weak self, weak host] in
                guard let self, let host, self.hosts[id] === host else { return }; self.states[id] = "已连接"
            }
            host.onDisconnected = { [weak self, weak host] in
                guard let self, let host, self.hosts[id] === host else { return }; self.states[id] = "等待连接"
            }
            host.onUnavailable = { [weak self, weak host] in
                guard let self, let host, self.hosts[id] === host else { return }
                self.hosts.removeValue(forKey: id); self.ports.removeValue(forKey: id)
                self.states[id] = "连接不可用"; self.message = SecureLinkError.connection.userMessage
            }
            host.onMessage = { [weak self, weak host] value in
                guard let self, let host, self.hosts[id] === host else { return }
                if case let .button(button) = value, button.id == "connection-test", button.phase == .up {
                    self.testCount += 1
                }
            }
            host.start()
        } catch { states[id] = "凭据不可用，请撤销后重新配对"; message = SecureLinkError.storage.userMessage }
    }
    public func revoke(_ id: UUID) {
        let host = hosts.removeValue(forKey: id); host?.stop(); ports.removeValue(forKey: id); states.removeValue(forKey: id)
        do { try store.remove(id: id); message = "已撤销。再次使用需要重新配对。" }
        catch { message = SecureLinkError.storage.userMessage }
        devices = store.devices
    }
}

@MainActor public final class ClientPairingModel: ObservableObject {
    @Published public private(set) var devices: [LinkDeviceRecord]
    @Published public private(set) var message = "在 Mac 的掌声设置中打开「手机」，再扫描二维码。"
    @Published public private(set) var busy = false
    @Published public private(set) var connectedID: UUID?
    private let store: LinkDeviceStore
    private var discovery: LinkDiscovery?
    private var pairing: PairingClient?
    private var client: SecureLinkClient?
    private var deadline: Task<Void, Never>?
    private var generation = UUID()
    public init(store: LinkDeviceStore) { self.store = store; devices = store.devices }

    public func pair(code: String) { pair(code: code, endpoint: nil) }
    // 测试注入回环端口；正常界面只允许按邀请标识发现。
    func pair(code: String, endpoint: NWEndpoint?) {
        stop()
        do {
            let invitation = try PairingInvitation(code: code.trimmingCharacters(in: .whitespacesAndNewlines))
            guard let id = UUID(uuidString: invitation.serviceName) else { throw SecureLinkError.invalidCode }
            busy = true; message = "正在寻找这台 Mac…"
            let token = generation
            find(id, pairing: true, endpoint: endpoint) { [weak self] endpoint in
                guard let self, self.generation == token else { return }
                do {
                    let exchange = try PairingClient(invitation: invitation, endpoint: endpoint, store: self.store)
                    self.pairing = exchange; self.message = "正在安全配对…"
                    exchange.onPaired = { [weak self] credential in
                        guard let self, self.generation == token else { return }
                        self.finishSearch(); self.pairing = nil; self.busy = false
                        do { try self.store.activate(id: credential.id); self.message = "配对成功，点击连接开始测试。" }
                        catch {
                            do { try self.store.remove(id: credential.id) } catch { /* 留给撤销重试。 */ }
                            self.message = SecureLinkError.storage.userMessage
                        }
                        self.devices = self.store.devices
                    }
                    exchange.onFailure = { [weak self] error in
                        guard let self, self.generation == token else { return }; self.fail(error)
                    }
                    exchange.start()
                } catch { self.fail((error as? SecureLinkError) ?? .connection) }
            }
        } catch { message = ((error as? SecureLinkError) ?? .invalidCode).userMessage }
    }
    public func connect(_ id: UUID) { connect(id, endpoint: nil) }
    func connect(_ id: UUID, endpoint: NWEndpoint?) {
        stop()
        do {
            guard let credential = try store.load(id: id) else { throw SecureLinkError.storage }
            busy = true; message = "正在寻找已配对的 Mac…"; let token = generation
            find(id, pairing: false, endpoint: endpoint) { [weak self] endpoint in
                guard let self, self.generation == token else { return }
                let client = SecureLinkClient(credential: credential, endpoint: endpoint); self.client = client
                client.onReady = { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.finishSearch(); self.busy = false; self.connectedID = id
                    self.message = "已连接。点击测试按钮后，在 Mac 上查看收到的次数。"
                }
                client.onDisconnected = { [weak self] _ in
                    guard let self, self.generation == token else { return }; self.fail(.connection)
                }
                client.start()
            }
        } catch { fail(.storage) }
    }
    private func find(_ id: UUID, pairing: Bool, endpoint: NWEndpoint?, found: @escaping (NWEndpoint) -> Void) {
        let token = generation
        deadline = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            guard let self, self.generation == token else { return }; self.fail(.timeout)
        }
        if let endpoint { found(endpoint); return }
        let browser = LinkDiscovery(); discovery = browser
        browser.onResults = { [weak self, weak browser] endpoints in
            guard let self, let browser, self.generation == token, self.discovery === browser,
                  let endpoint = endpoints.first else { return }
            browser.stop(); self.discovery = nil; found(endpoint)
        }
        browser.onUnavailable = { [weak self] in
            guard let self, self.generation == token else { return }; self.fail(.connection)
        }
        browser.start(serviceID: id, pairing: pairing)
    }
    private func finishSearch() { discovery?.stop(); discovery = nil; deadline?.cancel(); deadline = nil }
    public func stop() {
        generation = UUID(); finishSearch()
        let exchange = pairing; pairing = nil; exchange?.cancel()
        let old = client; client = nil; old?.stop()
        busy = false; connectedID = nil; devices = store.devices; message = "连接已停止，可点击连接重试。"
    }
    private func fail(_ error: SecureLinkError) { stop(); message = error.userMessage }
    public func sendTest() {
        guard connectedID != nil, let client else { return }
        do {
            try client.send(.button(RemoteButton(id: "connection-test", phase: .down)))
            try client.send(.button(RemoteButton(id: "connection-test", phase: .up)))
        } catch { fail(.connection) }
    }
    public func revoke(_ id: UUID) {
        // 撤销任一设备前结束当前操作，避免旧配对完成回调重新加入记录。
        stop()
        do { try store.remove(id: id); message = "已移除 Mac。再次使用需要重新配对。" }
        catch { message = SecureLinkError.storage.userMessage }
        devices = store.devices
    }
}
