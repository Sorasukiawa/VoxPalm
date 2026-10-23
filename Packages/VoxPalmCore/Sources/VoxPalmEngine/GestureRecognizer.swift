import Foundation

public enum GestureKind: String, Codable, CaseIterable, Sendable {
    case single
    case double
    case long

    public var title: String {
        switch self {
        case .single: return "单击"
        case .double: return "双击"
        case .long: return "长按"
        }
    }
}

public struct GestureTiming: Codable, Hashable, Sendable {
    /// 两次按下间隔小于它算双击
    public var doubleTapWindow: Double
    /// 按住超过它算长按
    public var longPressThreshold: Double

    public init(doubleTapWindow: Double = 0.3, longPressThreshold: Double = 0.45) {
        self.doubleTapWindow = doubleTapWindow
        self.longPressThreshold = longPressThreshold
    }

    /// 保留正常的自定义时长；异常配置不能溢出系统计时器或整数转换。
    static func safeInterval(_ value: Double, fallback: Double, allowsZero: Bool = false) -> Double {
        guard value.isFinite, allowsZero ? value >= 0 : value > 0,
              value < Double(Int64.max) / 1_000_000_000 else { return fallback }
        return value
    }

    var normalized: GestureTiming {
        GestureTiming(doubleTapWindow: Self.safeInterval(doubleTapWindow, fallback: 0.3),
                      longPressThreshold: Self.safeInterval(longPressThreshold, fallback: 0.45))
    }
}

/// 识别出来的手势。`pressBegan` / `pressEnded` 是原始的按下松开，语音会话用它提前开麦（预录）。
public enum RecognizedGesture: Equatable, Sendable {
    case pressBegan
    case pressEnded
    case single
    case double
    case longBegan
    case longEnded
}

/// 定时器抽象，方便测试时手动拨时间。
public protocol GestureScheduler: AnyObject {
    func schedule(after seconds: Double, _ work: @escaping () -> Void) -> AnyObject
    func cancel(_ token: AnyObject)
}

public final class MainQueueScheduler: GestureScheduler {
    public init() {}

    public func schedule(after seconds: Double, _ work: @escaping () -> Void) -> AnyObject {
        let item = DispatchWorkItem(block: work)
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return item
    }

    public func cancel(_ token: AnyObject) {
        (token as? DispatchWorkItem)?.cancel()
    }
}

/// 把按下 / 松开识别成单击、双击、长按。
/// 某个键没绑双击时，单击在松开时立刻触发，不用等双击窗口。
public final class GestureRecognizer {
    public var timing: GestureTiming {
        get { storedTiming }
        set { storedTiming = newValue.normalized }
    }
    /// 这个键（哪台设备的哪个键）这个手势有没有设动作
    public var hasBinding: (ButtonEvent, GestureKind) -> Bool = { _, _ in true }
    public var onGesture: ((ButtonEvent, RecognizedGesture) -> Void)?

    private enum State {
        case pressed(longTimer: AnyObject?, longFired: Bool)
        case waitingSecond(timer: AnyObject)
        case secondPressed
    }

    private let scheduler: GestureScheduler
    private var storedTiming: GestureTiming
    private var states: [String: State] = [:]
    private var lastEvent: [String: ButtonEvent] = [:]

    public init(timing: GestureTiming = GestureTiming(), scheduler: GestureScheduler = MainQueueScheduler()) {
        storedTiming = timing.normalized
        self.scheduler = scheduler
    }

    public func reset() {
        for state in states.values { cancelTimers(state) }
        states.removeAll()
        lastEvent.removeAll()
    }

    public func cancel(deviceID: String) {
        for key in Array(lastEvent.keys) where lastEvent[key]?.deviceID == deviceID {
            if let state = states.removeValue(forKey: key) { cancelTimers(state) }
            lastEvent.removeValue(forKey: key)
        }
    }

    public func handle(_ event: ButtonEvent) {
        let key = "\(event.deviceID)|\(event.button.rawValue)"
        lastEvent[key] = event
        switch event.phase {
        case .down: down(event, key: key)
        case .up: up(event, key: key)
        case .trigger: trigger(event, key: key)
        }
    }

    private func down(_ event: ButtonEvent, key: String) {
        switch states[key] {
        case .none:
            emit(event, .pressBegan)
            var timer: AnyObject?
            if hasBinding(event, .long) {
                timer = scheduler.schedule(after: timing.longPressThreshold) { [weak self] in self?.longFired(key) }
            }
            states[key] = .pressed(longTimer: timer, longFired: false)
        case let .waitingSecond(timer):
            scheduler.cancel(timer)
            emit(event, .pressBegan)
            states[key] = .secondPressed
        case .pressed, .secondPressed:
            // 重复的按下（有的设备按住会连发），忽略。
            break
        }
    }

    private func up(_ event: ButtonEvent, key: String) {
        switch states[key] {
        case let .pressed(timer, longFired):
            if let timer { scheduler.cancel(timer) }
            emit(event, .pressEnded)
            if longFired {
                states[key] = nil
                emit(event, .longEnded)
            } else if hasBinding(event, .double) {
                let timer = scheduler.schedule(after: timing.doubleTapWindow) { [weak self] in self?.doubleWindowExpired(key) }
                states[key] = .waitingSecond(timer: timer)
            } else {
                states[key] = nil
                emit(event, .single)
            }
        case .secondPressed:
            states[key] = nil
            emit(event, .pressEnded)
            emit(event, .double)
        case .waitingSecond, .none:
            break
        }
    }

    private func trigger(_ event: ButtonEvent, key: String) {
        switch states[key] {
        case let .waitingSecond(timer):
            scheduler.cancel(timer)
            states[key] = nil
            emit(event, .double)
        default:
            if hasBinding(event, .double) {
                let timer = scheduler.schedule(after: timing.doubleTapWindow) { [weak self] in self?.doubleWindowExpired(key) }
                states[key] = .waitingSecond(timer: timer)
            } else {
                emit(event, .single)
            }
        }
    }

    private func longFired(_ key: String) {
        guard case .pressed(_, false) = states[key], let event = lastEvent[key] else { return }
        states[key] = .pressed(longTimer: nil, longFired: true)
        emit(event, .longBegan)
    }

    private func doubleWindowExpired(_ key: String) {
        guard case .waitingSecond = states[key], let event = lastEvent[key] else { return }
        states[key] = nil
        emit(event, .single)
    }

    private func cancelTimers(_ state: State) {
        switch state {
        case let .pressed(timer, _): if let timer { scheduler.cancel(timer) }
        case let .waitingSecond(timer): scheduler.cancel(timer)
        case .secondPressed: break
        }
    }

    private func emit(_ event: ButtonEvent, _ gesture: RecognizedGesture) {
        onGesture?(event, gesture)
    }
}
