import Foundation
import Observation
import VoxPalmDevices

@MainActor @Observable final class FirmwareUpdateStore {
    struct Result {
        var check: DeviceFirmwareCheck?
        var package: DeviceFirmwarePackage?
        var problem: String?
        var installedVersion: String?
    }
    private(set) var results: [String: Result] = [:]
    private(set) var busyID: String?
    private(set) var preparing = false
    private(set) var isInstalling = false
    private(set) var installationProgress: DeviceFirmwareProgress?
    @ObservationIgnored private let provider: (any DeviceFirmwareProvider)?
    @ObservationIgnored private var identities: [String: UInt64] = [:]
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let timeout: Duration

    init(provider: (any DeviceFirmwareProvider)?, timeout: Duration = .seconds(100)) {
        self.provider = provider; self.timeout = timeout
    }
    func supports(_ info: HIDDeviceInfo?) -> Bool { info.map { provider?.supports($0) == true } ?? false }

    func configure(_ devices: [String: HIDDeviceInfo]) {
        let next = devices.mapValues(\.id)
        guard next != identities else { return }
        results = results.filter { (isInstalling && $0.key == busyID) || next[$0.key] == identities[$0.key] }
        identities = next
        if !isInstalling { generation = UUID() }
    }

    func check(id: String, device: HIDDeviceInfo) {
        guard busyID == nil, let provider, provider.supports(device), identities[id] == device.id else { return }
        start(id: id, preparing: false) { try await provider.check(device) }
    }

    func prepare(id: String) {
        guard busyID == nil, let provider, let check = results[id]?.check, check.canPrepare else { return }
        start(id: id, preparing: true) { try await provider.prepare(check.token) }
    }

    @discardableResult
    func install(id: String, completion: @escaping @MainActor (Bool) -> Void) -> Bool {
        guard busyID == nil, let provider, identities[id] != nil,
              let package = results[id]?.package, package.experimentalInstallation else { return false }
        busyID = id; isInstalling = true; preparing = false
        results[id]?.problem = nil
        installationProgress = DeviceFirmwareProgress(message: "正在重新核对设备、电量和固件包…")
        let token = UUID(); generation = token
        Task { [weak self] in
            var succeeded = false
            defer {
                self?.busyID = nil; self?.isInstalling = false; self?.installationProgress = nil
                completion(succeeded)
            }
            do {
                let version = try await provider.install(package.token) { [weak self] progress in
                    Task { @MainActor in
                        guard self?.generation == token, self?.isInstalling == true else { return }
                        self?.installationProgress = progress
                    }
                }
                self?.results[id] = Result(installedVersion: version)
                succeeded = true
            } catch {
                self?.results[id] = Result(problem: "\(error.localizedDescription) 控制监听保持暂停，请先核对设备状态。")
            }
        }
        return true
    }

    private func start<Value: Sendable>(id: String, preparing: Bool, operation: @escaping @Sendable () async throws -> Value) {
        busyID = id; self.preparing = preparing
        let token = UUID(); generation = token
        if preparing { results[id]?.problem = nil } else { results[id] = Result() }
        let timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.generation == token, self.busyID != nil else { return }
            self.generation = UUID()
            self.results[id, default: Result()].problem = "设备或网络响应超时。操作结束前不会启动另一项读取。"
        }
        Task { [weak self] in
            do {
                let value = try await operation()
                guard let self else { return }
                defer { self.busyID = nil; self.preparing = false }
                guard self.generation == token else { return }
                if let check = value as? DeviceFirmwareCheck { self.results[id] = Result(check: check) }
                if let package = value as? DeviceFirmwarePackage { self.results[id]?.package = package }
            } catch {
                guard let self else { return }
                defer { self.busyID = nil; self.preparing = false }
                guard self.generation == token else { return }
                self.results[id, default: Result()].problem = error.localizedDescription
            }
        }
    }
}
