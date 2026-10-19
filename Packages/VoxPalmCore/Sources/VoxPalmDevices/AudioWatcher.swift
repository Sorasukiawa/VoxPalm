import CoreAudio
import Foundation

/// 盯着 CoreAudio 的变化：设备连上 / 断开、系统默认输入输出被切换、采样率变化、音量和静音变化。
/// 蓝牙耳麦上的音量键、通话键有时只表现为设备音量变化，所以音量也记。
public final class AudioWatcher {
    public enum Event: Sendable {
        case deviceAdded(AudioDeviceInfo)
        case deviceRemoved(AudioDeviceInfo)
        case defaultInputChanged(from: AudioDeviceInfo?, to: AudioDeviceInfo?)
        case defaultOutputChanged(from: AudioDeviceInfo?, to: AudioDeviceInfo?)
        case defaultSystemOutputChanged(from: AudioDeviceInfo?, to: AudioDeviceInfo?)
        case sampleRateChanged(AudioDeviceInfo, Double)
        case runningChanged(AudioDeviceInfo, Bool)
        case volumeChanged(AudioDeviceInfo, scope: String, channel: Int, value: Float)
        case muteChanged(AudioDeviceInfo, scope: String, muted: Bool)
    }

    public var onEvent: ((Double, Event) -> Void)?

    private var known: [AudioObjectID: AudioDeviceInfo] = [:]
    private var defaults: [AudioObjectPropertySelector: AudioObjectID] = [:]
    private var listeners: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var deviceListeners: [AudioObjectID: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)]] = [:]

    private static let system = AudioObjectID(kAudioObjectSystemObject)
    private static let defaultSelectors = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDefaultSystemOutputDevice,
    ]

    public init() {}

    deinit {
        stop()
    }

    public func start() {
        guard listeners.isEmpty else { return }
        for device in AudioDevices.all() {
            known[device.id] = device
            watch(device)
        }
        for selector in Self.defaultSelectors {
            defaults[selector] = AudioDevices.defaultDevice(selector)
        }
        listen(Self.system, CoreAudioProperty.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.devicesChanged() }
        for selector in Self.defaultSelectors {
            listen(Self.system, CoreAudioProperty.address(selector)) { [weak self] in self?.defaultChanged(selector) }
        }
    }

    public func stop() {
        for (id, var address, block) in listeners {
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
        listeners.removeAll()
        for id in Array(deviceListeners.keys) { unwatch(id) }
        known.removeAll()
    }

    private func listen(_ id: AudioObjectID, _ address: AudioObjectPropertyAddress, _ handler: @escaping () -> Void) {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
        if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
            listeners.append((id, address, block))
        }
    }

    private func watch(_ device: AudioDeviceInfo) {
        let id = device.id
        var entries: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        func add(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain, _ handler: @escaping () -> Void) {
            var address = CoreAudioProperty.address(selector, scope: scope, element: element)
            guard AudioObjectHasProperty(id, &address) else { return }
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            if AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr {
                entries.append((address, block))
            }
        }
        add(kAudioDevicePropertyNominalSampleRate) { [weak self] in
            guard let self, let info = AudioDevices.device(id: id) else { return }
            self.known[id] = info
            self.emit(.sampleRateChanged(info, info.nominalSampleRate))
        }
        add(kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
            guard let self, let info = AudioDevices.device(id: id) else { return }
            self.known[id] = info
            self.emit(.runningChanged(info, info.isRunningSomewhere))
        }
        for (scope, name, channels) in [(kAudioObjectPropertyScopeInput, "input", device.inputChannels), (kAudioObjectPropertyScopeOutput, "output", device.outputChannels)] where channels > 0 {
            for element in 0...UInt32(channels) {
                add(kAudioDevicePropertyVolumeScalar, scope: scope, element: element) { [weak self] in
                    guard let self, let info = self.known[id] else { return }
                    let value: Float32 = CoreAudioProperty.value(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: element, default: -1)
                    self.emit(.volumeChanged(info, scope: name, channel: Int(element), value: value))
                }
            }
            add(kAudioDevicePropertyMute, scope: scope) { [weak self] in
                guard let self, let info = self.known[id] else { return }
                let muted: UInt32 = CoreAudioProperty.value(id, kAudioDevicePropertyMute, scope: scope, default: 0)
                self.emit(.muteChanged(info, scope: name, muted: muted != 0))
            }
        }
        deviceListeners[id] = entries
    }

    private func unwatch(_ id: AudioObjectID) {
        for (address, block) in deviceListeners.removeValue(forKey: id) ?? [] {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
    }

    private func devicesChanged() {
        let current = Dictionary(uniqueKeysWithValues: AudioDevices.all().map { ($0.id, $0) })
        for (id, info) in known where current[id] == nil {
            unwatch(id)
            known[id] = nil
            emit(.deviceRemoved(info))
        }
        for (id, info) in current where known[id] == nil {
            known[id] = info
            watch(info)
            emit(.deviceAdded(info))
        }
    }

    private func defaultChanged(_ selector: AudioObjectPropertySelector) {
        let old = defaults[selector].flatMap { known[$0] }
        let newID = AudioDevices.defaultDevice(selector)
        guard newID != defaults[selector] else { return }
        defaults[selector] = newID
        let new = AudioDevices.device(id: newID)
        if let new { known[newID] = new }
        switch selector {
        case kAudioHardwarePropertyDefaultInputDevice: emit(.defaultInputChanged(from: old, to: new))
        case kAudioHardwarePropertyDefaultOutputDevice: emit(.defaultOutputChanged(from: old, to: new))
        default: emit(.defaultSystemOutputChanged(from: old, to: new))
        }
    }

    private func emit(_ event: Event) {
        onEvent?(MonotonicClock.now(), event)
    }
}
