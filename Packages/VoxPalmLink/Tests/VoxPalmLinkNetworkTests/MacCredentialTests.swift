#if os(macOS)
import Foundation
import Security
import Testing
@testable import VoxPalmLinkNetwork

@Test @MainActor func Mac凭据限定命名空间不放宽ACL且错误不回退() throws {
    var queries: [[String: Any]] = []
    var stored: Data?
    var status = errSecSuccess
    let store = MacLoginCredentialStore(operations: .init(add: {
        queries.append($0); stored = $0[kSecValueData as String] as? Data; return status
    }, copy: { queries.append($0); return (status, stored) }, delete: { queries.append($0); return status }))
    let key = try LinkCredential(hostID: UUID(), clientID: UUID())
    try store.save(key)
    #expect(try store.load(id: key.id)?.secret == key.secret)
    try store.remove(id: key.id)
    for query in queries {
        #expect(query[kSecAttrService as String] as? String == "com.sorasukiawa.VoxPalm.link.mac-login.v1")
        #expect(query[kSecAttrAccount as String] as? String == key.id.uuidString)
        #expect(query[kSecUseDataProtectionKeychain as String] as? Bool == false)
        #expect(query[kSecAttrSynchronizable as String] as? Bool == false)
        #expect(query[kSecAttrAccess as String] == nil)
        #expect(query[kSecAttrAccessible as String] == nil)
    }
    queries.removeAll(); status = errSecAuthFailed
    #expect(throws: SecureLinkError.storage) { try store.save(key) }
    #expect(throws: SecureLinkError.storage) { _ = try store.load(id: key.id) }
    #expect(throws: SecureLinkError.storage) { try store.remove(id: key.id) }
    #expect(queries.count == 3)
}
#endif
