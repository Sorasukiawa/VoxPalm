import Foundation
import Security

public enum SecureLinkError: Error, Equatable, Sendable {
    case invalidCredential, invalidCode, expired, consumed, storage, connection, timeout, backlog, protocolViolation
}

/// 只能通过明确的配对码/钥匙串序列化接口导出；打印对象不会显示密钥。
public struct LinkCredential: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public let id: UUID
    public let hostID: UUID
    public let clientID: UUID
    let secret: Data
    public var description: String { "LinkCredential(<redacted>)" }
    public var debugDescription: String { description }

    public init(hostID: UUID, clientID: UUID) throws {
        guard hostID != clientID else { throw SecureLinkError.invalidCredential }
        id = UUID(); self.hostID = hostID; self.clientID = clientID
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw SecureLinkError.invalidCredential }
        secret = Data(bytes)
    }

    init(id: UUID, hostID: UUID, clientID: UUID, secret: Data) throws {
        guard secret.count == 32, hostID != clientID else { throw SecureLinkError.invalidCredential }
        self.id = id; self.hostID = hostID; self.clientID = clientID; self.secret = secret
    }

    // 固定字段、有界 JSON 只用于配对 TLS 内部和钥匙串；不是日志或公开发现信息。
    private struct Record: Codable {
        let version: Int; let id: UUID; let host: UUID; let client: UUID; let key: Data
    }
    func encoded() throws -> Data {
        try JSONEncoder().encode(Record(version: 1, id: id, host: hostID, client: clientID, key: secret))
    }
    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 1024 else { throw SecureLinkError.invalidCredential }
        guard let r = try? JSONDecoder().decode(Record.self, from: data), r.version == 1 else { throw SecureLinkError.invalidCredential }
        return try Self(id: r.id, hostID: r.host, clientID: r.client, secret: r.key)
    }
}

/// 二维码内容和手动粘贴内容相同；不应出现在 URL 查询、Bonjour TXT 或日志中。
public struct PairingInvitation: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let credential: LinkCredential
    public let expiresAt: Date
    public var serviceName: String { credential.id.uuidString }
    public var description: String { "PairingInvitation(<redacted>)" }
    public var debugDescription: String { description }
    public init(hostID: UUID, now: Date = .now) throws {
        credential = try LinkCredential(hostID: hostID, clientID: UUID())
        expiresAt = now.addingTimeInterval(300)
    }
    private struct Code: Codable { let version: Int; let expires: Date; let credential: Data }
    public func pairingCode() throws -> String {
        let data = try JSONEncoder().encode(Code(version: 1, expires: expiresAt, credential: credential.encoded()))
        return "VOXPALM1:" + data.base64EncodedString()
    }
    public init(code: String, now: Date = .now) throws {
        guard code.utf8.count <= 2048, code.hasPrefix("VOXPALM1:"),
              let data = Data(base64Encoded: String(code.dropFirst(9))),
              let record = try? JSONDecoder().decode(Code.self, from: data), record.version == 1 else { throw SecureLinkError.invalidCode }
        guard record.expires > now, record.expires.timeIntervalSince(now) <= 300 else { throw SecureLinkError.expired }
        credential = try LinkCredential.decode(record.credential); expiresAt = record.expires
    }
}

@MainActor public protocol LinkCredentialStore: AnyObject {
    func save(_ credential: LinkCredential) throws
    func remove(id: UUID) throws
    func load(id: UUID) throws -> LinkCredential?
}

/// 只操作本 App 服务命名空间；不会同步到其他设备，也不会请求放宽钥匙串访问权限。
@MainActor public final class KeychainLinkCredentialStore: LinkCredentialStore {
    private let service = "com.sorasukiawa.VoxPalm.link.v1"
    public init() {}
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id.uuidString, kSecUseDataProtectionKeychain as String: true,
         kSecAttrSynchronizable as String: false]
    }
    public func save(_ credential: LinkCredential) throws {
        var attributes = query(credential.id)
        attributes[kSecValueData as String] = try credential.encoded()
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        // 不覆盖已有配对材料；新配对使用新标识。
        guard status == errSecSuccess else { throw SecureLinkError.storage }
    }
    public func remove(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureLinkError.storage }
    }
    public func load(id: UUID) throws -> LinkCredential? {
        var q = query(id); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = value as? Data else { throw SecureLinkError.storage }
        return try LinkCredential.decode(data)
    }
}
