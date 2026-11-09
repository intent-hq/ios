import Foundation

/// Where one store's `*.subscribe` live state stands (WorkspaceStore, NoteStore,
/// TaskStore, CommentStore).
///
/// It replaces three fields that each store kept side by side: the acknowledged
/// subscription id, a "live" Bool (a snapshot was applied, so legacy events no
/// longer refetch) and a resnapshot guard (a gap repair is running, so further
/// gaps are ignored). Every combination of those three is reachable, so each
/// case below is one of them; the stores change it only through the named
/// transitions, never field by field.
///
/// The id is the subscription whose push handler the store registered. During
/// a resnapshot it is the old id while `*.unsubscribe` is in flight, nil while
/// resubscribing, and the new id once that is acknowledged.
enum LiveSubscription: Equatable {
    /// Whether the store's list follows `subscription.push` or legacy events.
    enum Feed: Equatable {
        /// No snapshot applied yet: legacy events refetch the list.
        case legacy
        /// A snapshot was applied: pushes drive the list.
        case live
    }

    /// Nothing acknowledged and no snapshot: the store runs on legacy events.
    case idle
    /// A snapshot was applied. `id` is nil only when a push was applied before
    /// any acknowledgement (tests inject pushes through `handleEvent`).
    case live(id: String?)
    /// A gap repair (unsubscribe, resubscribe, baseline refetch) is running.
    case resnapshotting(id: String?, feed: Feed)
    /// `*.subscribe` was acknowledged and its handler registered; no snapshot yet.
    case subscribed(id: String)

    /// Acknowledged subscription id, if any.
    var id: String? {
        switch self {
        case .idle: nil
        case let .subscribed(id): id
        case let .live(id): id
        case let .resnapshotting(id, _): id
        }
    }

    /// True once a snapshot made the list live; legacy refetches are skipped.
    var isLive: Bool {
        switch self {
        case .live, .resnapshotting(_, .live): true
        case .idle, .subscribed, .resnapshotting(_, .legacy): false
        }
    }

    /// True while a gap repair runs; further gaps must not start another.
    var isResnapshotting: Bool {
        if case .resnapshotting = self { return true }
        return false
    }

    private var feed: Feed { isLive ? .live : .legacy }

    private static func settled(id: String?, feed: Feed) -> Self {
        switch (id, feed) {
        case (nil, .legacy): .idle
        case let (id?, .legacy): .subscribed(id: id)
        case (_, .live): .live(id: id)
        }
    }

    private func replacing(id newId: String?, feed newFeed: Feed? = nil) -> Self {
        let nextFeed = newFeed ?? feed
        if isResnapshotting { return .resnapshotting(id: newId, feed: nextFeed) }
        return Self.settled(id: newId, feed: nextFeed)
    }

    // MARK: - Transitions

    /// `*.subscribe` acknowledged `newId`. Keeps the feed and any running
    /// resnapshot. Returns the previous id, whose handler the caller must
    /// unregister (even when it equals `newId`, as before).
    mutating func acknowledge(_ newId: String) -> String? {
        let previous = id
        self = replacing(id: newId)
        return previous
    }

    /// A snapshot push was applied.
    mutating func applySnapshot() {
        self = replacing(id: id, feed: .live)
    }

    /// Drops the id and keeps the feed (TaskStore's failed subscribe, and the
    /// step after a resnapshot's unsubscribe).
    mutating func clearId() {
        self = replacing(id: nil)
    }

    /// `*.subscribe` failed or acked without an id: drop the id and fall back
    /// to legacy events.
    mutating func subscribeFailed() {
        self = replacing(id: nil, feed: .legacy)
    }

    /// A sequence gap was detected. Starts a resnapshot and returns true,
    /// or returns false when one is already running. The feed is unchanged
    /// until the resnapshot itself starts.
    mutating func requestResnapshot() -> Bool {
        guard !isResnapshotting else { return false }
        self = .resnapshotting(id: id, feed: feed)
        return true
    }

    /// The resnapshot body starts: the list is no longer live.
    mutating func beginResnapshot() {
        self = .resnapshotting(id: id, feed: .legacy)
    }

    /// The resnapshot body finished. A no-op when a teardown already ended it.
    mutating func endResnapshot() {
        guard case let .resnapshotting(id, feed) = self else { return }
        self = Self.settled(id: id, feed: feed)
    }

    /// Teardown (reconnect, workspace or note switch). Returns the id whose
    /// handler the caller unregisters, if it does.
    @discardableResult
    mutating func reset() -> String? {
        let previous = id
        self = .idle
        return previous
    }
}
