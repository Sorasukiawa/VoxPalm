import Foundation
import VoxPalmDevices

/// 控制设备的来源。开源版有三种：HID 设备、系统按键（媒体键和键盘）、系统「正在播放」命令；
/// DJI 等闭源适配在私有包里实现同一个协议。所有回调都在主线程。
public protocol ControlSource: AnyObject {
    var sourceID: String { get }
    var onEvent: ((ButtonEvent) -> Void)? { get set }
    var onDevicesChanged: (() -> Void)? { get set }
    /// 被映射的键要不要拦下来（不再传给前台 App）。
    var isMapped: ((ButtonID) -> Bool)? { get set }
    var status: String { get }
    func devices() -> [ControlDevice]
    /// 只监听这些设备；传空集合就停掉。
    func activate(_ deviceIDs: Set<String>)
    /// App 退出前调用。接管了设备按键的来源（比如要让设备恢复普通按键）在这里收尾，完成后调 completion。
    func shutdown(completion: @escaping () -> Void)
    /// 这台设备的示意图（知道按键位置和键值时给出）；nil 表示让用户选一个外形再学键。
    func diagram(for device: ControlDevice) -> DeviceDiagram?
}

public extension ControlSource {
    func diagram(for device: ControlDevice) -> DeviceDiagram? { nil }

    func shutdown(completion: @escaping () -> Void) {
        activate([])
        completion()
    }
}

// MARK: - HID 设备

/// 遥控器、翻页笔、脚踏板等：直接读这台设备的 HID 按键，能分清是哪台设备按的。
public final class HIDControlSource: ControlSource {
    public let sourceID = "hid"
    public var onEvent: ((ButtonEvent) -> Void)?
    public var onDevicesChanged: (() -> Void)?
    public var isMapped: ((ButtonID) -> Bool)?
    public private(set) var status = "未启用"

    private var monitor: HIDMonitor?
    private var active: Set<String> = []

    public init() {}

    public static func deviceID(_ info: HIDDeviceInfo) -> String { "hid:" + info.physicalKey }

    public func devices() -> [ControlDevice] {
        var seen = Set<String>()
        var result: [ControlDevice] = []
        let all = HIDMonitor.snapshot().filter { !$0.isBuiltIn }
        for info in all where seen.insert(info.physicalKey).inserted {
            let siblings = all.filter { $0.physicalKey == info.physicalKey }
            let kinds = Array(Set(siblings.flatMap(\.kinds))).sorted().joined(separator: "、")
            result.append(ControlDevice(
                id: Self.deviceID(info), sourceID: sourceID, name: info.displayName,
                detail: "\(info.transport ?? "HID") · \(info.vendorProduct) · \(kinds)", reportsRelease: true
            ))
        }
        return result
    }

    public func activate(_ deviceIDs: Set<String>) {
        active = deviceIDs.filter { $0.hasPrefix("hid:") }
        guard !active.isEmpty else {
            monitor?.stop()
            monitor = nil
            status = "未启用"
            return
        }
        if monitor == nil {
            let monitor = HIDMonitor()
            monitor.deviceFilter = { [weak self] info in self?.active.contains(Self.deviceID(info)) ?? false }
            monitor.onValue = { [weak self] value in self?.handle(value) }
            monitor.onDeviceChange = { [weak self] _ in self?.onDevicesChanged?() }
            monitor.start()
            self.monitor = monitor
        }
        status = HIDAccess.isGranted ? "监听中" : "缺少输入监控权限"
    }

    private func handle(_ value: HIDMonitor.ValueEvent) {
        guard value.isButtonLike else { return }
        onEvent?(ButtonEvent(
            deviceID: Self.deviceID(value.device),
            button: .hid(page: value.usagePage, usage: value.usage),
            label: value.usageLabel,
            phase: value.value != 0 ? .down : .up,
            time: value.time
        ))
    }
}

// MARK: - 系统按键

/// 系统收到的媒体键和键盘按键。看不出是哪台设备按的，但不认识的设备（蓝牙耳机按键、翻页笔）也能用。
/// 有辅助功能权限时，映射过的键会被拦下来，不再传给前台 App。
public final class SystemKeysControlSource: ControlSource {
    public static let mediaDeviceID = "system:media"
    public static let keyboardDeviceID = "system:keyboard"

    public let sourceID = "system-keys"
    public var onEvent: ((ButtonEvent) -> Void)?
    public var onDevicesChanged: (() -> Void)?
    public var isMapped: ((ButtonID) -> Bool)?
    public private(set) var status = "未启用"

    private var monitor: SystemEventMonitor?
    private var active: Set<String> = []

    public init() {}

    public func devices() -> [ControlDevice] {
        [
            ControlDevice(id: Self.mediaDeviceID, sourceID: sourceID, name: "系统媒体键",
                          detail: "播放、音量等媒体键：蓝牙耳机按键、遥控器、键盘的 F7–F12", reportsRelease: true),
            ControlDevice(id: Self.keyboardDeviceID, sourceID: sourceID, name: "键盘按键（所有键盘）",
                          detail: "翻页笔、小键盘发出的普通按键；映射后这个键在所有键盘上都会被拦下", reportsRelease: true),
        ]
    }

    public func diagram(for device: ControlDevice) -> DeviceDiagram? {
        device.id == Self.mediaDeviceID ? .mediaKeys : nil
    }

    public func activate(_ deviceIDs: Set<String>) {
        active = deviceIDs.filter { $0.hasPrefix("system:") && $0 != NowPlayingControlSource.deviceID }
        monitor?.stop()
        monitor = nil
        guard !active.isEmpty else {
            status = "未启用"
            return
        }
        let canFilter = KeyPoster.canPost
        let monitor = SystemEventMonitor(mode: canFilter ? .filter : .listenOnly, includeKeyboard: active.contains(Self.keyboardDeviceID))
        monitor.onEvent = { [weak self] in self?.handle($0) }
        monitor.shouldSuppress = { [weak self] in self?.shouldSuppress($0) ?? false }
        let started = monitor.start()
        self.monitor = started ? monitor : nil
        status = !started ? "缺少输入监控权限" : canFilter ? "监听中，映射过的键会被拦下" : "只能监听（没有辅助功能权限，拦不下原来的键）"
    }

    private func convert(_ event: SystemEventMonitor.Event) -> ButtonEvent? {
        switch event {
        case let .mediaKey(key):
            guard active.contains(Self.mediaDeviceID), !key.isRepeat else { return nil }
            return ButtonEvent(deviceID: Self.mediaDeviceID, button: .media(key.keyCode), label: key.name,
                               phase: key.isDown ? .down : .up, time: key.time)
        case let .key(key):
            guard active.contains(Self.keyboardDeviceID), key.phase != .modifiers, !key.isRepeat else { return nil }
            return ButtonEvent(deviceID: Self.keyboardDeviceID, button: .key(key.keyCode),
                               label: KeyCodeNames.label(keyCode: key.keyCode, characters: key.characters),
                               phase: key.phase == .down ? .down : .up, time: key.time)
        }
    }

    private func handle(_ event: SystemEventMonitor.Event) {
        guard let converted = convert(event) else { return }
        onEvent?(converted)
    }

    private func shouldSuppress(_ event: SystemEventMonitor.Event) -> Bool {
        switch event {
        case let .mediaKey(key) where active.contains(Self.mediaDeviceID):
            return isMapped?(.media(key.keyCode)) ?? false
        case let .key(key) where active.contains(Self.keyboardDeviceID) && key.phase != .modifiers:
            return isMapped?(.key(key.keyCode)) ?? false
        default:
            return false
        }
    }
}

/// 键盘按键的名字。功能键、方向键这类按出来不是字（是看不见的控制字符或私用区字符），用固定的名字。
public enum KeyCodeNames {
    public static let special: [Int: String] = [
        36: "↩", 48: "⇥", 49: "空格", 51: "⌫", 53: "⎋", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
    ]

    /// 学键时记下的名字，比如「按键 F18（79）」「按键 a（0）」
    public static func label(keyCode: Int, characters: String?) -> String {
        let typed = characters.flatMap { text in
            !text.isEmpty && text.unicodeScalars.allSatisfy { ![.control, .privateUse].contains($0.properties.generalCategory) } ? text : nil
        }
        guard let name = special[keyCode] ?? typed else { return "按键 \(keyCode)" }
        return "按键 \(name)（\(keyCode)）"
    }
}

// MARK: - 正在播放

/// 蓝牙耳机、遥控器的 AVRCP 播放控制。系统把它发给「正在播放」的 App，所以启用时掌声会登记成正在播放，
/// 别的播放器暂时收不到这些命令。只有一次性触发，没有松开，做不了长按。
public final class NowPlayingControlSource: ControlSource {
    public static let deviceID = "system:now-playing"

    public let sourceID = "now-playing"
    public var onEvent: ((ButtonEvent) -> Void)?
    public var onDevicesChanged: (() -> Void)?
    public var isMapped: ((ButtonID) -> Bool)?
    public private(set) var status = "未启用"

    private var monitor: RemoteCommandMonitor?

    public init() {}

    public func devices() -> [ControlDevice] {
        [ControlDevice(id: Self.deviceID, sourceID: sourceID, name: "播放控制（蓝牙 AVRCP）",
                       detail: "蓝牙耳机、音箱、遥控器的播放 / 暂停 / 切歌命令；只能单击和双击", reportsRelease: false)]
    }

    public func activate(_ deviceIDs: Set<String>) {
        guard deviceIDs.contains(Self.deviceID) else {
            monitor?.stop()
            monitor = nil
            status = "未启用"
            return
        }
        guard monitor == nil else { return }
        let monitor = RemoteCommandMonitor()
        monitor.onEvent = { [weak self] event in
            let phase: ButtonEvent.Phase = event.phase == "begin" ? .down : event.phase == "end" ? .up : .trigger
            self?.onEvent?(ButtonEvent(deviceID: Self.deviceID, button: .remote(event.command), label: event.command, phase: phase, time: event.time))
        }
        monitor.start(title: "掌声 VoxPalm")
        self.monitor = monitor
        status = "已登记为正在播放"
    }
}
