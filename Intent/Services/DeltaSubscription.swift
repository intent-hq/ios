import Foundation

/// Parsed subscription.push envelope from the daemon.
struct SubscriptionPush {
    let subscriptionId: String
    let kind: Kind
    let seq: Int
    let snapshot: [[String: Any]]?
    let delta: DeltaPayload?
    /// Snapshot-level metadata for object-shaped snapshots (chat channel):
    /// agentId, truncated, totalMessages, nextToken, plus activity flags like
    /// isResponding, isWaitingOnTool, turnInFlight, lastStreamActivityAt.
    /// Nil for array-shaped snapshots (collection channels).
    var snapshotMeta: [String: Any]? = nil
    
    enum Kind {
        case snapshot
        case delta
    }
    
    struct DeltaPayload {
        let added: [[String: Any]]
        let updated: [[String: Any]]
        let removedIds: [String]
    }
    
    /// Parse a daemon notification into a SubscriptionPush, or nil if it isn't one.
    static func parse(method: String, params: Any) -> SubscriptionPush? {
        guard method == "subscription.push",
              let dict = params as? [String: Any],
              let subscriptionId = dict["subscriptionId"] as? String,
              let seq = dict["seq"] as? Int else {
            return nil
        }

        if let kindStr = dict["kind"] as? String, kindStr == "snapshot" {
            // Collection channels: snapshot is an array of entities.
            if let snapshot = dict["snapshot"] as? [[String: Any]] {
                return SubscriptionPush(
                    subscriptionId: subscriptionId,
                    kind: .snapshot,
                    seq: seq,
                    snapshot: snapshot,
                    delta: nil
                )
            }
            // Chat channel: snapshot is an object with a "messages" array plus
            // snapshot-level metadata/activity flags (PROTOCOL §7.1).
            if let snapshotObj = dict["snapshot"] as? [String: Any],
               let messages = snapshotObj["messages"] as? [[String: Any]] {
                var meta = snapshotObj
                meta.removeValue(forKey: "messages")
                return SubscriptionPush(
                    subscriptionId: subscriptionId,
                    kind: .snapshot,
                    seq: seq,
                    snapshot: messages,
                    delta: nil,
                    snapshotMeta: meta
                )
            }
            return nil // Malformed: no snapshot array and no snapshot.messages
        } else if let kindStr = dict["kind"] as? String, kindStr == "delta" {
            guard let deltaDict = dict["delta"] as? [String: Any] else {
                return nil // Malformed: delta push must have "delta" field
            }
            let added = (deltaDict["added"] as? [[String: Any]]) ?? []
            let updated = (deltaDict["updated"] as? [[String: Any]]) ?? []
            let removedIds = (deltaDict["removedIds"] as? [String]) ?? []
            let delta = DeltaPayload(added: added, updated: updated, removedIds: removedIds)
            return SubscriptionPush(
                subscriptionId: subscriptionId,
                kind: .delta,
                seq: seq,
                snapshot: nil,
                delta: delta
            )
        }
        return nil
    }
}

/// Reconciles snapshot/delta pushes into an id-keyed collection with stable ordering.
class DeltaReconciler<T> {
    private var items = [String: T]()
    private var orderedIds = [String]()
    private var expectedSeq = 0
    private var seeded = false

    private let getId: ([String: Any]) -> String?
    private let normalize: ([String: Any]) -> T?

    init(getId: @escaping ([String: Any]) -> String?, normalize: @escaping ([String: Any]) -> T?) {
        self.getId = getId
        self.normalize = normalize
    }

    // Workaround for a swift-frontend (6.3.3) SIGSEGV: the EarlyPerfInliner SIL pass
    // crashes in isCallerAndCalleeLayoutConstraintsCompatible while optimizing the
    // compiler-generated deinit of this generic class in Release builds
    // (-O -enable-default-cmo). An explicit deinit marked @_optimize(none) keeps the
    // optimizer out of this one function; behavior is identical (stored properties
    // are still released normally).
    @_optimize(none)
    deinit {}

    /// Forget all state so the next snapshot rebuilds from scratch.
    func reset() {
        items.removeAll()
        orderedIds.removeAll()
        expectedSeq = 0
        seeded = false
    }

    /// Replace the whole collection from a snapshot push.
    func applySnapshot(seq: Int, rawItems: [[String: Any]]) {
        items.removeAll()
        orderedIds.removeAll()
        for raw in rawItems {
            upsert(raw)
        }
        expectedSeq = seq + 1
        seeded = true
    }

    /// Apply a contiguous delta; false means a gap → caller should resnapshot.
    func applyDelta(seq: Int, delta: SubscriptionPush.DeltaPayload) -> Bool {
        guard seeded, seq == expectedSeq else {
            return false
        }
        for raw in delta.added {
            upsert(raw)
        }
        for raw in delta.updated {
            upsert(raw)
        }
        for id in delta.removedIds {
            items.removeValue(forKey: id)
            orderedIds.removeAll { $0 == id }
        }
        expectedSeq = seq + 1
        return true
    }

    /// Current collection as an array preserving server snapshot/insertion order.
    func values() -> [T] {
        return orderedIds.compactMap { items[$0] }
    }

    private func upsert(_ raw: [String: Any]) {
        guard let id = getId(raw), let normalized = normalize(raw) else {
            return
        }
        if items[id] == nil {
            orderedIds.append(id)
        }
        items[id] = normalized
    }
}
