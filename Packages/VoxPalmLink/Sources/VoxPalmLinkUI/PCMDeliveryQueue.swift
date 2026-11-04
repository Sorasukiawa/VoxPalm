import Foundation

/// 关闭时先等正在执行的入队返回。调用方随后在锁外 Stop/Dispose，音频回调不会再使用旧快照入队。
final class AudioEnqueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = true
    func enqueue(_ operation: () -> Bool) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard open else { return nil }; return operation()
    }
    func close() { lock.lock(); open = false; lock.unlock() }
}

/// 音频线程到主线程只保留有限数据、最多一个待执行通知，不为每块声音排无限个任务。
final class PCMDeliveryQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [Data] = []
    private var bytes = 0
    private var scheduled = false
    private var closed = false
    private var failed = false
    private let maximumBytes: Int
    private let notify: @Sendable () -> Void
    init(maximumBytes: Int = 64 * 1024, notify: @escaping @Sendable () -> Void) {
        self.maximumBytes = maximumBytes; self.notify = notify
    }
    func append(_ data: Data) {
        lock.lock()
        guard !closed, !failed else { lock.unlock(); return }
        if data.count > maximumBytes - bytes {
            failed = true; buffers.removeAll(); bytes = 0
        } else { buffers.append(data); bytes += data.count }
        let wake = !scheduled; scheduled = true
        lock.unlock()
        if wake { notify() }
    }
    func drain() -> (buffers: [Data], failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        let result = (buffers, failed)
        buffers.removeAll(); bytes = 0; scheduled = false
        return result
    }
    func fail() {
        lock.lock()
        guard !closed, !failed else { lock.unlock(); return }
        failed = true; buffers.removeAll(); bytes = 0
        let wake = !scheduled; scheduled = true; lock.unlock()
        if wake { notify() }
    }
    func close() {
        lock.lock(); closed = true; buffers.removeAll(); bytes = 0; lock.unlock()
    }
}
