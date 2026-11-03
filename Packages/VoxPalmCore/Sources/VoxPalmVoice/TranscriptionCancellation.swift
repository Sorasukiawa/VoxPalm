import Foundation

/// Swift Task 的取消标记不能直接跨到 C 回调或 DispatchQueue；每个任务各持有一份信号。
final class TranscriptionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }

    /// 只在同步任务真正退出后返回，保证 C 回调仍在用的信号和模型不会提前释放。
    static func run<T>(on queue: DispatchQueue, operation: @escaping (TranscriptionCancellation) throws -> T) async throws -> T {
        let cancellation = TranscriptionCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try cancellation.check()
                        let result = try operation(cancellation)
                        try cancellation.check()
                        return result
                    })
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }
}

/// 取消回调和错误收尾可能同时到达；异步清理只执行一次，并允许调用方等待完成。
final class TranscriptionCleanup: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private let action: () async -> Void

    init(_ action: @escaping () async -> Void) { self.action = action }

    @discardableResult
    func start() -> Task<Void, Never> {
        lock.lock()
        defer { lock.unlock() }
        if let task { return task }
        let action = action
        let next = Task { await action() }
        task = next
        return next
    }
}
