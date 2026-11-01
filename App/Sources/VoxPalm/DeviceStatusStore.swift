import Foundation
import Observation
import VoxPalmDevices

enum HardwareStatusTarget: Sendable {
    case hid(HIDDeviceInfo)
    case audio(AudioDeviceInfo)
    case unavailable(String)

    var identity: String {
        switch self {
        case .hid(let info): return "hid:\(info.id)"
        case .audio(let info): return "audio:\(info.id):\(info.uid)"
        case .unavailable(let reason): return "unavailable:\(reason)"
        }
    }
}

struct DeviceStatusReadRequest: Sendable {
    let targets: [String: HardwareStatusTarget]
    let batteries: [ControllerBatteryReading]
    let supplements: [String: DeviceHardwareStatus]
    let queryUSBDeviceID: String?
}

/// 只留当前连接的状态；后台查询串行，超时后也不并发堆积新查询。
@MainActor @Observable final class DeviceStatusStore {
    private(set) var values: [String: DeviceHardwareStatus] = [:]
    private(set) var isRefreshing = false
    private(set) var isBusy = false
    private(set) var problem: String?
    @ObservationIgnored private var identities: [String: String] = [:]
    @ObservationIgnored private var epoch = UUID()
    @ObservationIgnored private var lastRefresh = Date.distantPast
    @ObservationIgnored private var lastUSBQueryIdentity: String?
    @ObservationIgnored private let reader: @Sendable (DeviceStatusReadRequest) -> [String: DeviceHardwareStatus]
    @ObservationIgnored private let timeout: Duration

    init(reader: @escaping @Sendable (DeviceStatusReadRequest) -> [String: DeviceHardwareStatus] = { DeviceStatusStore.read($0) },
         timeout: Duration = .seconds(3)) {
        self.reader = reader; self.timeout = timeout
    }

    func configure(_ targets: [String: HardwareStatusTarget]) {
        let next = targets.mapValues(\.identity)
        guard next != identities else { return }
        values = values.filter { next[$0.key] == identities[$0.key] }
        identities = next; epoch = UUID(); lastRefresh = .distantPast
        lastUSBQueryIdentity = nil
        isRefreshing = false
    }

    func refresh(targets: [String: HardwareStatusTarget], batteries: [ControllerBatteryReading],
                 supplements: [String: DeviceHardwareStatus], queryUSBDeviceID: String?, force: Bool) {
        configure(targets)
        let queryIdentity = queryUSBDeviceID.flatMap { targets[$0]?.identity }
        let changedSelection = queryIdentity != nil && queryIdentity != lastUSBQueryIdentity
        guard !isBusy, force || changedSelection || Date().timeIntervalSince(lastRefresh) >= 15 else { return }
        isBusy = true; isRefreshing = true; problem = nil
        let token = UUID(); epoch = token
        let request = DeviceStatusReadRequest(targets: targets, batteries: batteries, supplements: supplements, queryUSBDeviceID: queryUSBDeviceID)
        let reader = self.reader, timeout = self.timeout
        Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, self.epoch == token, self.isBusy else { return }
            self.epoch = UUID(); self.isRefreshing = false
            self.problem = "设备响应较慢，本次结果不再采用；读取结束后可以重试。"
        }
        Task.detached(priority: .utility) { [weak self] in
            let results = reader(request)
            await self?.complete(results, token: token, queryIdentity: queryIdentity)
        }
    }

    nonisolated private static func read(_ request: DeviceStatusReadRequest) -> [String: DeviceHardwareStatus] {
        let physicalHIDs = Dictionary(request.targets.values.compactMap { target -> (String, HIDDeviceInfo)? in
            if case .hid(let info) = target { return (info.controlKey, info) }; return nil
        }, uniquingKeysWith: { first, _ in first })
        let names = physicalHIDs.values.map(\.displayName)
        let queryIdentity = request.queryUSBDeviceID.flatMap { request.targets[$0]?.identity }
        var results: [String: DeviceHardwareStatus] = [:]
        var cache: [String: DeviceHardwareStatus] = [:]
        for (id, target) in request.targets {
            var value: DeviceHardwareStatus
            if let cached = cache[target.identity] { value = cached }
            else {
                switch target {
                case .hid(let info):
                    value = DeviceStatusReader.hid(info, queryUSBReports: target.identity == queryIdentity)
                    if value.battery == nil, value.problem == nil {
                        value.battery = DeviceStatusReader.uniqueBattery(name: info.displayName, hardwareNames: names, readings: request.batteries)
                    }
                case .audio(let info): value = DeviceStatusReader.audio(info)
                case .unavailable(let reason): value = DeviceHardwareStatus(problem: reason)
                }
                cache[target.identity] = value
            }
            value.supplement(request.supplements[id]); results[id] = value
        }
        return results
    }

    private func complete(_ results: [String: DeviceHardwareStatus], token: UUID, queryIdentity: String?) {
        isBusy = false; isRefreshing = false
        guard epoch == token else { return }
        if let queryIdentity { lastUSBQueryIdentity = queryIdentity }
        for (id, var result) in results {
            // 本模块不写固件；同一连接中可沿用已核实的版本，电量则必须来自本次读取。
            if result.firmware == nil, result.problem == nil, let old = values[id], let version = old.firmware {
                result.firmware = version; result.firmwareNote = old.firmwareNote
            }
            values[id] = result
        }
        lastRefresh = Date()
    }
}
