import AppKit
import VoxPalmDevices
import VoxPalmEngine

extension AppModel {
    func hardwareTargets() -> [String: HardwareStatusTarget] {
        let groups = Dictionary(grouping: HIDMonitor.snapshot().filter { !$0.isBuiltIn }, by: { HIDControlSource.deviceID($0) })
        var targets: [String: HardwareStatusTarget] = [:]
        for device in devices {
            if let infos = groups[device.id] {
                targets[device.id] = DeviceStatusReader.uniqueHID(infos).map(HardwareStatusTarget.hid)
                    ?? .unavailable("同型号设备身份不明确，暂不显示可能串台的状态")
            } else if let source = engine.sources.first(where: { $0.sourceID == device.sourceID }),
                      let uid = source.associatedAudioUID(for: device.id), let mic = micDevices.first(where: { $0.uid == uid }) {
                targets[device.id] = .audio(mic)
            } else {
                targets[device.id] = .unavailable(device.id.hasPrefix("system:") || device.id.hasPrefix("now-playing:")
                    ? "此来源不区分物理设备，无法显示单台设备状态" : "此设备没有提供可读取的硬件状态")
            }
        }
        for mic in micDevices {
            if let profile = mic.controllerProfile {
                let matching = groups.values.compactMap(DeviceStatusReader.uniqueHID).filter { $0.profile == profile && $0.transport == "USB" }
                let micCount = micDevices.filter { $0.controllerProfile == profile }.count
                if matching.count == 1, micCount == 1 { targets[mic.uid] = .hid(matching[0]); continue }
            }
            targets[mic.uid] = .audio(mic)
        }
        for mic in externalMicDevices {
            if let controlID = mic.controlDeviceID, let target = targets[controlID] { targets[mic.uid] = target }
        }
        return targets
    }

    func hardwareStatus(for id: String) -> DeviceHardwareStatus? { deviceStatus.values[id] }
    func hardwareDeviceConnected(_ id: String) -> Bool {
        devices.contains { $0.id == id } || micDevices.contains { $0.uid == id } || externalMicDevices.contains { $0.uid == id }
    }

    func refreshHardwareStatus(deviceID: String? = nil, force: Bool = false) {
        guard !isDeviceStatusPreview, voiceState == .idle, firmwareUpdates.busyID == nil else { return }
        let targets = hardwareTargets()
        firmwareUpdates.configure(targets.compactMapValues { if case .hid(let info) = $0 { return info }; return nil })
        var supplements: [String: DeviceHardwareStatus] = [:]
        for device in devices {
            guard let source = engine.sources.first(where: { $0.sourceID == device.sourceID }),
                  let status = source.hardwareStatus(for: device.id) else { continue }
            supplements[device.id] = status
            if let uid = source.associatedAudioUID(for: device.id) { supplements[uid] = status }
        }
        deviceStatus.refresh(targets: targets, batteries: DeviceStatusReader.controllerBatteries(),
                             supplements: supplements,
                             queryUSBDeviceID: deviceID ?? (isDeviceStatusPageVisible ? deviceStatusPageSelection : nil), force: force)
    }

    var isDeviceStatusPageVisible: Bool {
        deviceStatusPageVisible && NSApp.windows.contains { $0.title == "掌声设置" && $0.isVisible }
    }

    var shouldRefreshHardwareStatus: Bool {
        panelVisible || isDeviceStatusPageVisible
    }
}
