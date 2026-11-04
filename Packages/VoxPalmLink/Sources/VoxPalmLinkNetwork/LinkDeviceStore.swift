import Foundation

/// 不含密钥。待完成/待删除记录绝不获得连接权，失败后仍能定位并清理钥匙串项。
public struct LinkDeviceRecord: Codable, Identifiable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case pending, paired, removing }
    public let id: UUID
    public let hostID: UUID
    public let clientID: UUID
    public var state: State
    public let createdAt: Date
}

@MainActor public final class LinkDeviceStore: LinkCredentialStore {
    private struct Directory: Codable {
        var version = 1
        let identity: UUID
        var devices: [LinkDeviceRecord]
    }
    private let url: URL
    private let credentials: any LinkCredentialStore
    private var directory: Directory
    private var lastData: Data?
    private var locallyRevoked: Set<UUID> = []
    public var identity: UUID { directory.identity }
    public var devices: [LinkDeviceRecord] { directory.devices }

    public init(url: URL, credentials: any LinkCredentialStore) throws {
        self.url = url; self.credentials = credentials
        do {
            let data = try Self.read(url)
            lastData = data
            if let data {
                let decoded = try JSONDecoder().decode(Directory.self, from: data)
                guard decoded.version == 1, decoded.devices.count <= 32,
                      Set(decoded.devices.map(\.id)).count == decoded.devices.count,
                      decoded.devices.allSatisfy({ $0.hostID != $0.clientID && $0.createdAt.timeIntervalSince1970.isFinite }) else {
                    throw SecureLinkError.storage
                }
                directory = decoded
            } else { directory = Directory(identity: UUID(), devices: []) }
        } catch { throw SecureLinkError.storage }
    }

    private static func read(_ url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber, size.intValue <= 65_536 else { throw SecureLinkError.storage }
        let data = try Data(contentsOf: url)
        guard data.count <= 65_536 else { throw SecureLinkError.storage }
        return data
    }

    private func write(_ next: Directory) throws {
        do {
            let data = try JSONEncoder().encode(next)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var coordinationError: NSError?
            var writeError: Error?
            // 多个窗口/进程使用旧快照时拒绝覆盖；只写自己的独立目录文件。
            NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
                do {
                    guard try Self.read(target) == lastData else { throw SecureLinkError.storage }
                    try data.write(to: target, options: .atomic)
                } catch { writeError = error }
            }
            guard coordinationError == nil, writeError == nil else { throw SecureLinkError.storage }
            lastData = data; directory = next
        } catch { throw SecureLinkError.storage }
    }

    public func save(_ credential: LinkCredential) throws {
        guard directory.devices.count < 32, !directory.devices.contains(where: { $0.id == credential.id }) else {
            throw SecureLinkError.storage
        }
        var next = directory
        next.devices.append(LinkDeviceRecord(id: credential.id, hostID: credential.hostID,
                                             clientID: credential.clientID, state: .pending, createdAt: .now))
        try write(next)
        // 此处崩溃或写入失败也有可清理的记录；不会自动恢复成可信设备。
        try credentials.save(credential)
    }

    public func activate(id: UUID) throws {
        guard let index = directory.devices.firstIndex(where: { $0.id == id && $0.state == .pending }),
              let key = try credentials.load(id: id), key.id == id,
              key.hostID == directory.devices[index].hostID, key.clientID == directory.devices[index].clientID else {
            throw SecureLinkError.storage
        }
        var next = directory; next.devices[index].state = .paired; try write(next)
    }

    public func load(id: UUID) throws -> LinkCredential? {
        guard !locallyRevoked.contains(id) else { return nil }
        // 其他实例已撤销/更改目录时，旧对象不能继续用缓存授予新连接。
        guard try Self.read(url) == lastData else { throw SecureLinkError.storage }
        guard let record = directory.devices.first(where: { $0.id == id && $0.state == .paired }) else { return nil }
        guard let key = try credentials.load(id: id), key.id == record.id,
              key.hostID == record.hostID, key.clientID == record.clientID else { throw SecureLinkError.storage }
        return key
    }

    public func remove(id: UUID) throws {
        guard let index = directory.devices.firstIndex(where: { $0.id == id }) else { throw SecureLinkError.storage }
        // 即使磁盘写入失败，本次运行也不能通过重新打开开关恢复刚撤销的凭据。
        locallyRevoked.insert(id)
        var next = directory; next.devices[index].state = .removing; try write(next)
        try credentials.remove(id: id)
        next.devices.removeAll { $0.id == id }; try write(next)
    }
}
