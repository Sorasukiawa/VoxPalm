import Foundation

/// 主线程上的查询状态；IOKit 读操作在后台完成后凭票据交回结果。
struct HIDInputPollingState {
    struct Ticket {
        let deviceID: UInt64
        let generation: UUID
        let startedAt: Double
    }
    private struct Entry {
        let generation = UUID()
        var lastStream: Double
        var retryAfter: Double = 0
        var acceptedTime: Double = 0
    }
    private var entries: [UInt64: Entry] = [:]
    private var pending: Set<UUID> = []

    mutating func activate(_ id: UInt64, now: Double) {
        if entries[id] == nil { entries[id] = Entry(lastStream: now) }
    }
    mutating func deactivate(_ id: UInt64) { entries.removeValue(forKey: id) }
    mutating func stop() { entries.removeAll() }
    mutating func acceptStream(_ id: UInt64, eventTime: Double, now: Double) -> Bool {
        guard let entry = entries[id] else { return true }
        guard eventTime >= entry.acceptedTime else { return false }
        entries[id]?.lastStream = now
        entries[id]?.acceptedTime = eventTime
        return true
    }

    mutating func begin(_ id: UInt64, now: Double) -> Ticket? {
        guard let entry = entries[id], now - entry.lastStream >= 0.25, now >= entry.retryAfter,
              pending.insert(entry.generation).inserted else { return nil }
        return Ticket(deviceID: id, generation: entry.generation, startedAt: now)
    }

    /// 恢复流、断线重连或停止以后到达的旧结果，全部丢弃。
    mutating func complete(_ ticket: Ticket, now: Double, succeeded: Bool) -> Bool {
        pending.remove(ticket.generation)
        guard let entry = entries[ticket.deviceID], entry.generation == ticket.generation,
              entry.lastStream <= ticket.startedAt else { return false }
        if !succeeded { entries[ticket.deviceID]?.retryAfter = now + 1 }
        else { entries[ticket.deviceID]?.acceptedTime = max(entry.acceptedTime, ticket.startedAt) }
        return succeeded
    }
}
