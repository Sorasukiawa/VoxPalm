import Foundation

/// 通用固件界面契约。具体目录、包格式和传输协议由设备模块负责。
public struct DeviceFirmwareCheck: Equatable, Sendable {
    public enum Comparison: Sendable { case current, available, newerThanCatalogue }
    public let token: UUID
    public let installed: String
    public let latest: String
    public let comparison: Comparison
    public let checkedAt: Date
    public let canPrepare: Bool
    public let explanation: String

    public init(token: UUID, installed: String, latest: String, comparison: Comparison,
                checkedAt: Date, canPrepare: Bool, explanation: String) {
        self.token = token; self.installed = installed; self.latest = latest; self.comparison = comparison
        self.checkedAt = checkedAt; self.canPrepare = canPrepare; self.explanation = explanation
    }
}

public struct DeviceFirmwarePackage: Equatable, Sendable {
    public let token: UUID
    public let version: String
    public let byteCount: Int
    public let sha256: String
    public let explanation: String
    public let experimentalInstallation: Bool
    public init(token: UUID = UUID(), version: String, byteCount: Int, sha256: String, explanation: String, experimentalInstallation: Bool = false) {
        self.token = token; self.experimentalInstallation = experimentalInstallation
        self.version = version; self.byteCount = byteCount; self.sha256 = sha256; self.explanation = explanation
    }
}

public struct DeviceFirmwareProgress: Sendable {
    public let message: String
    public let completed: Int
    public let total: Int
    public init(message: String, completed: Int = 0, total: Int = 0) {
        self.message = message; self.completed = completed; self.total = total
    }
}

/// 检查和准备均不能写设备；安装必须使用已准备的单次令牌，并单独确认。
public protocol DeviceFirmwareProvider: Sendable {
    func supports(_ device: HIDDeviceInfo) -> Bool
    func check(_ device: HIDDeviceInfo) async throws -> DeviceFirmwareCheck
    func prepare(_ token: UUID) async throws -> DeviceFirmwarePackage
    func install(_ token: UUID, progress: @escaping @Sendable (DeviceFirmwareProgress) -> Void) async throws -> String
}

public extension DeviceFirmwareProvider {
    func install(_ token: UUID, progress: @escaping @Sendable (DeviceFirmwareProgress) -> Void) async throws -> String {
        throw FirmwareInstallationUnavailable()
    }
}

public struct FirmwareInstallationUnavailable: LocalizedError {
    public init() {}
    public var errorDescription: String? { "当前设备模块不提供安装操作。" }
}
