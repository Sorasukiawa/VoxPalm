import AppKit
import CoreGraphics

/// 用事件监听（CGEventTap）看系统收到的键盘事件和媒体键（NX_SYSDEFINED）。
/// 这条通道看不出事件来自哪台设备，但能看到遥控器、耳机按键被系统翻译成的媒体键。
public final class SystemEventMonitor {
    public struct MediaKeyEvent: Sendable {
        public let time: Double
        public let keyCode: Int
        public let isDown: Bool
        public let isRepeat: Bool
        public let data1: Int

        public var name: String { MediaKeyNames.name(keyCode) }
    }

    public struct KeyEvent: Sendable {
        public enum Phase: String, Sendable { case down, up, modifiers }

        public let time: Double
        public let keyCode: Int
        public let phase: Phase
        public let isRepeat: Bool
        public let flags: UInt64
        public let characters: String?
    }

    public enum Event: Sendable {
        case mediaKey(MediaKeyEvent)
        case key(KeyEvent)
    }

    public enum Mode {
        /// 只监听，事件照常传下去（需要「输入监控」权限）。
        case listenOnly
        /// 可以吞掉事件（需要「辅助功能」权限），App 把映射过的键拦下来用。
        case filter
    }

    public var onEvent: ((Event) -> Void)?
    /// 只在 `.filter` 模式下生效：返回 true 的事件不再传给别的 App。
    public var shouldSuppress: ((Event) -> Bool)?

    private let mode: Mode
    private let includeKeyboard: Bool
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    public init(mode: Mode = .listenOnly, includeKeyboard: Bool = true) {
        self.mode = mode
        self.includeKeyboard = includeKeyboard
    }

    deinit {
        stop()
    }

    /// 掌声自己模拟出来的事件带这个标记（写在 eventSourceUserData 里），监听时跳过，免得把自己发的键当成设备按键。
    public static let syntheticMarker: Int64 = 0x566F_7850 // "VoxP"

    public static var hasListenAccess: Bool { CGPreflightListenEventAccess() }

    @discardableResult
    public static func requestListenAccess() -> Bool { CGRequestListenEventAccess() }

    public var isRunning: Bool { tap != nil }

    /// 返回 false 表示没权限，建不了监听。
    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        var mask: CGEventMask = 1 << 14 // NX_SYSDEFINED
        if includeKeyboard {
            mask |= (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: mode == .listenOnly ? .listenOnly : .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<SystemEventMonitor>.fromOpaque(context).takeUnretainedValue()
                return monitor.handle(type: type, event: event)
            },
            userInfo: context
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticMarker { return Unmanaged.passUnretained(event) }
        guard let parsed = Self.parse(type: type, event: event) else { return Unmanaged.passUnretained(event) }
        onEvent?(parsed)
        if mode == .filter, shouldSuppress?(parsed) == true { return nil }
        return Unmanaged.passUnretained(event)
    }

    static func parse(type: CGEventType, event: CGEvent) -> Event? {
        let now = MonotonicClock.now()
        switch type.rawValue {
        case 14:
            // 子类型 8 是「辅助控制键」：data1 高 16 位是键码，低 16 位里 0xA 表示按下、0xB 表示松开，最低位表示自动连发。
            guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return nil }
            let data1 = ns.data1
            let flags = data1 & 0xFFFF
            let state = (flags & 0xFF00) >> 8
            return .mediaKey(MediaKeyEvent(
                time: now,
                keyCode: (data1 & 0xFFFF_0000) >> 16,
                isDown: state == 0xA,
                isRepeat: flags & 0x1 == 1,
                data1: data1
            ))
        case CGEventType.keyDown.rawValue, CGEventType.keyUp.rawValue, CGEventType.flagsChanged.rawValue:
            let phase: KeyEvent.Phase = type == .keyDown ? .down : type == .keyUp ? .up : .modifiers
            return .key(KeyEvent(
                time: now,
                keyCode: Int(event.getIntegerValueField(.keyboardEventKeycode)),
                phase: phase,
                isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                flags: event.flags.rawValue,
                characters: phase == .modifiers ? nil : NSEvent(cgEvent: event)?.charactersIgnoringModifiers
            ))
        default:
            return nil
        }
    }
}
