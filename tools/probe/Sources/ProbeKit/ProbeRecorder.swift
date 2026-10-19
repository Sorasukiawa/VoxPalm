import Foundation
import VoxPalmDevices

/// 同时开着所有监听通道，把事件统一记下来。监听器跑在主线程，向导在后台线程读结果，所以存取都加锁。
public final class ProbeRecorder: @unchecked Sendable {
    public struct ChannelStatus: Codable, Sendable {
        public var hid: String
        public var systemEvents: String
        public var remoteCommands: String
        public var audio: String
    }

    /// 只记录这些 HID 设备的输入；默认是全部外接设备（内置键盘、触控板不记）。
    public var hidFilter: (HIDDeviceInfo) -> Bool = { !$0.isBuiltIn }
    public var recordsRawReports = true
    /// 系统键盘事件会包括你在内置键盘上打的字，所以只在测试的那几秒里记。
    public var includeKeyboardEvents = true
    public var onLive: ((ProbeEvent) -> Void)?

    public let origin = MonotonicClock.now()
    public private(set) var status = ChannelStatus(hid: "未启动", systemEvents: "未启动", remoteCommands: "未启动", audio: "未启动")

    private let lock = NSLock()
    private var events: [ProbeEvent] = []
    private var capturing = false
    private var lastSignal: Double?
    private var maxEvents = 20_000

    private let hid = HIDMonitor()
    private var system: SystemEventMonitor?
    private let remote = RemoteCommandMonitor()
    private let audio = AudioWatcher()

    public init() {}

    /// 要在主线程调。
    public func startMonitors(nowPlayingTitle: String = "VoxPalm Probe") {
        hid.deviceFilter = { [weak self] in self?.hidFilter($0) ?? false }
        hid.recordsRawReports = recordsRawReports
        hid.onValue = { [weak self] in self?.record(value: $0) }
        hid.onReport = { [weak self] in self?.record(report: $0) }
        hid.onDeviceChange = { [weak self] change in
            guard let self else { return }
            switch change {
            case let .added(info):
                self.append(ProbeEvent(t: self.rel(MonotonicClock.now()), channel: .device, device: info.displayName, deviceKey: info.physicalKey, control: "HID 设备", phase: .added))
            case let .removed(info):
                self.append(ProbeEvent(t: self.rel(MonotonicClock.now()), channel: .device, device: info.displayName, deviceKey: info.physicalKey, control: "HID 设备", phase: .removed))
            }
        }
        hid.start()
        status.hid = hid.openResult == kIOReturnSuccess ? "正常" : (HIDAccess.isGranted ? "部分设备打不开（\(hid.openResult)）" : "没有输入监控权限，读不到键盘类设备")

        let system = SystemEventMonitor(mode: .listenOnly, includeKeyboard: includeKeyboardEvents)
        system.onEvent = { [weak self] in self?.record(system: $0) }
        status.systemEvents = system.start() ? "正常" : "没有输入监控权限，建不了系统事件监听"
        self.system = system

        remote.onEvent = { [weak self] event in
            guard let self else { return }
            let phase: ProbeEvent.Phase = event.phase == "begin" ? .down : event.phase == "end" ? .up : .trigger
            self.append(ProbeEvent(t: self.rel(event.time), channel: .remoteCommand, control: event.command, phase: phase, raw: event.detail))
        }
        remote.start(title: nowPlayingTitle)
        status.remoteCommands = "已登记为正在播放"

        audio.onEvent = { [weak self] time, event in self?.record(audio: event, at: time) }
        audio.start()
        status.audio = "正常"
    }

    public func stopMonitors() {
        hid.stop()
        system?.stop()
        remote.stop()
        audio.stop()
    }

    public var hidDevices: [HIDDeviceInfo] { hid.devices }

    // MARK: - 录制窗口

    public func beginCapture() {
        lock.lock()
        events.removeAll()
        lastSignal = nil
        capturing = true
        lock.unlock()
    }

    public func endCapture() -> [ProbeEvent] {
        lock.lock()
        defer { lock.unlock() }
        capturing = false
        return events
    }

    /// 录制窗口里最后一个按键信号的时间（相对启动）。
    public var lastSignalTime: Double? {
        lock.lock()
        defer { lock.unlock() }
        return lastSignal
    }

    public func now() -> Double { rel(MonotonicClock.now()) }

    // MARK: - 各通道转换

    private func rel(_ time: Double) -> Double { ((time - origin) * 1000).rounded() / 1000 }

    private func append(_ event: ProbeEvent) {
        lock.lock()
        guard capturing, events.count < maxEvents else {
            lock.unlock()
            return
        }
        events.append(event)
        if event.isSignal { lastSignal = event.t }
        lock.unlock()
        onLive?(event)
    }

    private func record(value: HIDMonitor.ValueEvent) {
        let phase: ProbeEvent.Phase = value.isButtonLike ? (value.value != 0 ? .down : .up) : .value
        append(ProbeEvent(
            t: rel(value.time), channel: .hid, device: value.device.displayName, deviceKey: value.device.physicalKey,
            control: value.usageLabel, phase: phase, value: Double(value.value),
            raw: String(format: "page 0x%02X usage 0x%02X report %d", value.usagePage, value.usage, value.reportID)
        ))
    }

    private func record(report: HIDMonitor.ReportEvent) {
        guard hidFilter(report.device) else { return }
        append(ProbeEvent(
            t: rel(report.time), channel: .hidReport, device: report.device.displayName, deviceKey: report.device.physicalKey,
            control: "报告 #\(report.reportID)", phase: .value, raw: report.hex
        ))
    }

    private func record(system event: SystemEventMonitor.Event) {
        switch event {
        case let .mediaKey(key):
            let phase: ProbeEvent.Phase = key.isRepeat ? .repeat : (key.isDown ? .down : .up)
            append(ProbeEvent(t: rel(key.time), channel: .mediaKey, control: key.name, phase: phase,
                              value: Double(key.keyCode), raw: String(format: "data1 0x%08X", key.data1)))
        case let .key(key):
            let phase: ProbeEvent.Phase = key.phase == .modifiers ? .change : key.isRepeat ? .repeat : (key.phase == .down ? .down : .up)
            let name = key.characters.flatMap { $0.isEmpty ? nil : $0.unicodeScalars.allSatisfy { $0.value >= 0x20 } ? $0 : nil }
            append(ProbeEvent(t: rel(key.time), channel: .key, control: "keyCode \(key.keyCode)" + (name.map { "（\($0)）" } ?? ""),
                              phase: phase, value: Double(key.keyCode), raw: String(format: "flags 0x%llX", key.flags)))
        }
    }

    private func record(audio event: AudioWatcher.Event, at time: Double) {
        let t = rel(time)
        switch event {
        case let .deviceAdded(info):
            append(ProbeEvent(t: t, channel: .device, device: info.name, deviceKey: info.uid, control: "音频设备", phase: .added))
        case let .deviceRemoved(info):
            append(ProbeEvent(t: t, channel: .device, device: info.name, deviceKey: info.uid, control: "音频设备", phase: .removed))
        case let .defaultInputChanged(_, to):
            append(ProbeEvent(t: t, channel: .audio, device: to?.name, deviceKey: to?.uid, control: "系统默认输入", phase: .change))
        case let .defaultOutputChanged(_, to):
            append(ProbeEvent(t: t, channel: .audio, device: to?.name, deviceKey: to?.uid, control: "系统默认输出", phase: .change))
        case let .defaultSystemOutputChanged(_, to):
            append(ProbeEvent(t: t, channel: .audio, device: to?.name, deviceKey: to?.uid, control: "系统提示音输出", phase: .change))
        case let .sampleRateChanged(info, rate):
            append(ProbeEvent(t: t, channel: .audio, device: info.name, deviceKey: info.uid, control: "采样率", phase: .change, value: rate))
        case let .runningChanged(info, running):
            append(ProbeEvent(t: t, channel: .audio, device: info.name, deviceKey: info.uid, control: "有程序在用", phase: .change, value: running ? 1 : 0))
        case let .volumeChanged(info, scope, channel, value):
            append(ProbeEvent(t: t, channel: .audio, device: info.name, deviceKey: info.uid,
                              control: "音量 \(scope == "input" ? "输入" : "输出") 声道\(channel)", phase: .change, value: Double(value)))
        case let .muteChanged(info, scope, muted):
            append(ProbeEvent(t: t, channel: .audio, device: info.name, deviceKey: info.uid,
                              control: "静音 \(scope == "input" ? "输入" : "输出")", phase: .change, value: muted ? 1 : 0))
        }
    }
}
