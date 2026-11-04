#if os(macOS)
import Foundation
import Security

/// 当前 Mac 打包没有提供数据保护钥匙串所需的 provisioning profile。
/// 显式使用系统本地登录钥匙串及默认的创建者 App ACL，不在数据保护接口失败后悄悄回退。
/// 锁定行为由登录钥匙串设置决定，不承诺 iOS 的 WhenUnlockedThisDeviceOnly 语义。
@MainActor public final class MacLoginCredentialStore: LinkCredentialStore {
    struct Operations {
        var add: ([String: Any]) -> OSStatus
        var copy: ([String: Any]) -> (OSStatus, Data?)
        var delete: ([String: Any]) -> OSStatus
        static var system: Self {
            Self(add: { SecItemAdd($0 as CFDictionary, nil) }, copy: {
                var result: CFTypeRef?
                let status = SecItemCopyMatching($0 as CFDictionary, &result)
                return (status, result as? Data)
            }, delete: { SecItemDelete($0 as CFDictionary) })
        }
    }
    private let operations: Operations
    public init() { operations = .system }
    init(operations: Operations) { self.operations = operations }
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.sorasukiawa.VoxPalm.link.mac-login.v1",
         kSecAttrAccount as String: id.uuidString,
         kSecUseDataProtectionKeychain as String: false, kSecAttrSynchronizable as String: false]
    }
    public func save(_ credential: LinkCredential) throws {
        var attributes = query(credential.id)
        attributes[kSecValueData as String] = try credential.encoded()
        // 不传自定义 kSecAttrAccess：系统默认 ACL 仅信任创建条目的 App。
        guard operations.add(attributes) == errSecSuccess else { throw SecureLinkError.storage }
    }
    public func load(id: UUID) throws -> LinkCredential? {
        var attributes = query(id); attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.copy(attributes)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data else { throw SecureLinkError.storage }
        return try LinkCredential.decode(data)
    }
    public func remove(id: UUID) throws {
        let status = operations.delete(query(id))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureLinkError.storage }
    }
}
#endif
