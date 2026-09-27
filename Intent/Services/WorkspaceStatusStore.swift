import Combine
import Foundation
import Observation

/// Shared status ownership for one backend. Hook feeds are workspace scoped;
/// the PR monitor feed is global, with the same per-workspace seed lifecycle.
@MainActor
@Observable final class WorkspaceStatusStore<Row> {
    typealias Fold = ([Row], String, [String: Any]) -> (rows: [Row], needsRefetch: Bool)

    @Observable final class Bucket {
        var rows: [Row] = []
        var isLoading = false
        var isStale = true
        var error: String?
        @ObservationIgnored var consumers: Set<UUID> = []
        @ObservationIgnored var generation = 0
        @ObservationIgnored var attempted = false
        @ObservationIgnored var loadTask: Task<Void, Never>?
        @ObservationIgnored var events: [(String, [String: Any])] = []
        @ObservationIgnored var recoveryIDs: Set<String> = []
    }

    final class Feed {
        let epoch: Int
        var id: String?
        var task: Task<Bool, Never>?
        var error: String?

        init(epoch: Int) { self.epoch = epoch }
    }

    /// Queued cleanup retains this observer, even after the store dies, so a
    /// reconnect between scheduling and issuing cleanup invalidates the ID.
    final class ConnectionLifetime {
        var epoch = 0
        var observation: AnyCancellable?
    }

    private(set) var buckets: [String: Bucket] = [:]
    @ObservationIgnored var feeds: [String: Feed] = [:]
    @ObservationIgnored var eventHandlerId: UUID?
    @ObservationIgnored var handlerGeneration = 0
    @ObservationIgnored let connectionLifetime = ConnectionLifetime()
    var connectionEpoch: Int { connectionLifetime.epoch }
    let connection: any ConnectionManagerRouting
    let family: String
    let listKey: String
    let globalFeed: Bool
    let replaceGroup: String
    let eventIDKey: String
    let removalEvents: Set<String>
    let parse: ([String: Any]) -> Row?
    let fold: Fold

    init(
        connection: any ConnectionManagerRouting,
        family: String,
        listKey: String,
        globalFeed: Bool,
        replaceGroup: String,
        eventIDKey: String,
        removalEvents: Set<String>,
        parse: @escaping ([String: Any]) -> Row?,
        fold: @escaping Fold
    ) {
        self.connection = connection
        self.family = family
        self.listKey = listKey
        self.globalFeed = globalFeed
        self.replaceGroup = replaceGroup
        self.eventIDKey = eventIDKey
        self.removalEvents = removalEvents
        self.parse = parse
        self.fold = fold
        var previousState = connection.connectionState
        connectionLifetime.observation = connection.connectionStatePublisher
            .sink { [weak self, weak lifetime = connectionLifetime] state in
                guard let lifetime, previousState != state else { return }
                let wasConnected = previousState == .connected
                previousState = state
                if wasConnected || state == .connected {
                    lifetime.epoch &+= 1
                    self?.invalidateConnection()
                }
                guard let self, state == .connected else { return }
                for (workspaceId, bucket) in buckets where !bucket.consumers.isEmpty {
                    Task { await self.load(workspaceId: workspaceId) }
                }
            }
    }

    isolated deinit {
        if let eventHandlerId { connection.removeEventHandler(id: eventHandlerId) }
        for feed in feeds.values {
            releaseRemote(feed)
        }
    }

    @discardableResult
    func retain(workspaceId: String, consumer: UUID = UUID()) -> UUID {
        let bucket = buckets[workspaceId] ?? Bucket()
        if buckets[workspaceId] == nil { buckets[workspaceId] = bucket }
        bucket.consumers.insert(consumer)
        return consumer
    }

    /// Remove this consumer synchronously. Pending ACKs are left alive so their
    /// captured remote IDs can be released without touching a successor feed.
    @discardableResult
    func release(workspaceId: String, consumer: UUID) -> Task<Void, Never>? {
        guard let bucket = buckets[workspaceId], bucket.consumers.remove(consumer) != nil,
              bucket.consumers.isEmpty else { return nil }
        invalidate(bucket)
        let key = feedKey(workspaceId)
        guard !buckets.contains(where: { feedKey($0.key) == key && !$0.value.consumers.isEmpty }) else { return nil }
        let feed = feeds.removeValue(forKey: key)
        if feeds.isEmpty { removeHandler() }
        return feed.flatMap { releaseRemote($0) }
    }

    func reset() {
        for bucket in buckets.values { invalidate(bucket) }
        buckets = [:]
        for feed in feeds.values {
            releaseRemote(feed)
        }
        feeds = [:]
        removeHandler()
    }

    private func invalidateConnection() {
        for bucket in buckets.values { invalidate(bucket) }
        // The old socket owns these IDs. Never unsubscribe them on a new socket.
        feeds = [:]
        removeHandler()
    }

    private func invalidate(_ bucket: Bucket) {
        bucket.generation &+= 1
        // The independent feed task must survive cancellation to release late
        // ACKs; list reads have no remote ownership and can be cancelled now.
        bucket.loadTask?.cancel()
        bucket.loadTask = nil
        bucket.events = []
        bucket.recoveryIDs = []
        bucket.attempted = false
        bucket.isLoading = false
        bucket.isStale = true
    }

    func feedKey(_ workspaceId: String) -> String { globalFeed ? "" : workspaceId }

    func removeHandler() {
        handlerGeneration &+= 1
        if let eventHandlerId { connection.removeEventHandler(id: eventHandlerId) }
        eventHandlerId = nil
    }

    func owns(_ bucket: Bucket, workspaceId: String, generation: Int) -> Bool {
        buckets[workspaceId] === bucket && bucket.generation == generation && !bucket.consumers.isEmpty
    }
}
