import Foundation

/// MainActor-owned routing and bounded replay state for subscription.push notifications.
@MainActor
final class ConnectionSubscriptionRouter {
    static let defaultBufferLimit = 64
    static let defaultBufferTTL: TimeInterval = 30

    private struct BufferedPush {
        let push: SubscriptionPush
        let receivedAt: Date
    }

    private var handlers: [String: @MainActor (SubscriptionPush) -> Void] = [:]
    private var buffer: [BufferedPush] = []
    private var recentlyUnregisteredIds: [String: Date] = [:]
    private let bufferLimit: Int
    private let bufferTTL: TimeInterval
    private let now: @MainActor () -> Date

    init(
        bufferLimit: Int = defaultBufferLimit,
        bufferTTL: TimeInterval = defaultBufferTTL,
        now: @escaping @MainActor () -> Date = Date.init
    ) {
        self.bufferLimit = bufferLimit
        self.bufferTTL = bufferTTL
        self.now = now
    }

    func register(id: String, handler: @escaping @MainActor (SubscriptionPush) -> Void) {
        handlers[id] = handler
        recentlyUnregisteredIds.removeValue(forKey: id)
        AppLog.connection.debug("[ConnectionManager] Registered subscription handler for id=\(id)")
        replayBufferedPushes(for: id, to: handler)
    }

    func unregister(id: String) {
        handlers.removeValue(forKey: id)
        let currentDate = now()
        pruneExpiredState(now: currentDate)
        buffer.removeAll { $0.push.subscriptionId == id }
        recentlyUnregisteredIds[id] = currentDate
        AppLog.connection.debug("[ConnectionManager] Unregistered subscription handler for id=\(id)")
    }

    /// Returns true when the notification is subscription.push, including malformed pushes.
    func route(method: String, params: Any) -> Bool {
        guard method == "subscription.push" else { return false }
        guard let push = SubscriptionPush.parse(method: method, params: params) else {
            let paramsDictionary = params as? [String: Any] ?? [:]
            let subscriptionId = paramsDictionary["subscriptionId"] as? String ?? "nil"
            let keys = paramsDictionary.keys.sorted().joined(separator: ", ")
            AppLog.connection.warning("[ConnectionManager] Malformed subscription.push dropped (subscriptionId=\(subscriptionId), keys=[\(keys)])")
            return true
        }

        if let handler = handlers[push.subscriptionId] {
            handler(push)
        } else {
            bufferUnrouted(push)
        }
        return true
    }

    func reset() {
        guard !handlers.isEmpty || !buffer.isEmpty || !recentlyUnregisteredIds.isEmpty else { return }
        AppLog.connection.debug("[ConnectionManager] Clearing \(handlers.count) subscription handler(s), \(buffer.count) buffered push(es) on disconnect")
        handlers.removeAll()
        buffer.removeAll()
        recentlyUnregisteredIds.removeAll()
    }

    var handlerCount: Int { handlers.count }
    var bufferedPushCount: Int { buffer.count }

    func hasBufferedPush(for id: String) -> Bool {
        buffer.contains { $0.push.subscriptionId == id }
    }

    func hasRecentlyUnregisteredId(_ id: String) -> Bool {
        recentlyUnregisteredIds[id] != nil
    }

    private func bufferUnrouted(_ push: SubscriptionPush) {
        let currentDate = now()
        pruneExpiredState(now: currentDate)
        if recentlyUnregisteredIds[push.subscriptionId] != nil {
            if push.kind == .snapshot && push.seq == 0 {
                recentlyUnregisteredIds.removeValue(forKey: push.subscriptionId)
            } else {
                AppLog.connection.debug("[ConnectionManager] Dropped subscription.push for recently unregistered id=\(push.subscriptionId) seq=\(push.seq)")
                return
            }
        }
        buffer.append(BufferedPush(push: push, receivedAt: currentDate))
        if buffer.count > bufferLimit {
            buffer.removeFirst(buffer.count - bufferLimit)
        }
        AppLog.connection.debug("[ConnectionManager] Buffered unrouted subscription.push for id=\(push.subscriptionId) seq=\(push.seq) (no handler registered yet, buffered=\(buffer.count))")
    }

    private func replayBufferedPushes(
        for id: String,
        to handler: @MainActor (SubscriptionPush) -> Void
    ) {
        pruneExpiredState(now: now())
        let matching = buffer.filter { $0.push.subscriptionId == id }
        guard !matching.isEmpty else { return }
        buffer.removeAll { $0.push.subscriptionId == id }
        AppLog.connection.debug("[ConnectionManager] Replaying \(matching.count) buffered push(es) for id=\(id)")
        for entry in matching {
            handler(entry.push)
        }
    }

    private func pruneExpiredState(now: Date) {
        let cutoff = now.addingTimeInterval(-bufferTTL)
        buffer.removeAll { $0.receivedAt < cutoff }
        recentlyUnregisteredIds = recentlyUnregisteredIds.filter { $0.value >= cutoff }
    }
}