import Foundation

/// Parsed subscription.push envelope from the daemon.
///
/// Nonisolated so `parse` can run in the off-main inbound frame parse
/// (`ConnectionManager.parseInboundFrame`), where chat-channel payloads are
/// also pre-decoded into typed values (`snapshotMessages`,
/// `DeltaPayload.chatBlocks`) so MainActor only merges them. `@unchecked
/// Sendable`: the raw dictionaries are parsed JSON containers that are never
/// mutated after parse.
nonisolated struct SubscriptionPush: @unchecked Sendable {
    let subscriptionId: String
    let kind: Kind
    let seq: Int
    let snapshot: [[String: Any]]?
    let delta: DeltaPayload?
    /// Snapshot-level metadata for object-shaped snapshots (chat channel):
    /// agentId, truncated, totalMessages, nextToken, plus activity flags like
    /// isResponding, isWaitingOnTool, turnInFlight, lastStreamActivityAt.
    /// Nil for array-shaped snapshots (collection channels).
    let snapshotMeta: [String: Any]?
    /// Chat-channel snapshot `messages` pre-decoded by `parse` (undecodable
    /// rows dropped, matching `ConversationMessage.parseMessage`). Nil for
    /// collection channels and for pushes built without `parse`.
    let snapshotMessages: [ConversationMessage]?

    enum Kind {
        case snapshot
        case delta
    }

    /// One chat-channel block delta entity (PROTOCOL §7.1) with its `block`
    /// decoded into a `ContentBlock`.
    struct ChatBlockEntity {
        let messageId: String
        let block: ContentBlock
        /// Role of the owning message; defaults to `.assistant` when absent.
        let role: MessageRole
        let timestamp: String?
        let streamingComplete: Bool

        /// Nil when the entity is not block-shaped or its block does not decode.
        init?(entity: [String: Any]) {
            guard let messageId = entity["messageId"] as? String,
                  let blockDictionary = entity["block"] as? [String: Any],
                  let block = ContentBlock.decode(blockDictionary)
            else {
                return nil
            }
            self.messageId = messageId
            self.block = block
            role = MessageRole(rawValue: entity["role"] as? String ?? "assistant") ?? .system
            timestamp = entity["timestamp"] as? String
            streamingComplete = entity["streamingComplete"] as? Bool ?? false
        }
    }

    struct DeltaPayload {
        let added: [[String: Any]]
        let updated: [[String: Any]]
        let removedIds: [String]
        /// `added` then `updated` pre-decoded as chat block entities by
        /// `parse` (entities that are not block-shaped or do not decode are
        /// dropped). Nil when no entity is block-shaped (collection channels)
        /// and for payloads built without `parse`.
        let chatBlocks: [ChatBlockEntity]?

        init(added: [[String: Any]], updated: [[String: Any]], removedIds: [String],
             chatBlocks: [ChatBlockEntity]? = nil) {
            self.added = added
            self.updated = updated
            self.removedIds = removedIds
            self.chatBlocks = chatBlocks
        }

        /// Decodes `added` + `updated` into chat block entities; nil when none
        /// of them is block-shaped.
        static func decodeChatBlocks(added: [[String: Any]], updated: [[String: Any]]) -> [ChatBlockEntity]? {
            let entities = added + updated
            guard entities.contains(where: { $0["block"] is [String: Any] }) else { return nil }
            return entities.compactMap { ChatBlockEntity(entity: $0) }
        }
    }

    init(subscriptionId: String, kind: Kind, seq: Int, snapshot: [[String: Any]]?,
         delta: DeltaPayload?, snapshotMeta: [String: Any]? = nil,
         snapshotMessages: [ConversationMessage]? = nil) {
        self.subscriptionId = subscriptionId
        self.kind = kind
        self.seq = seq
        self.snapshot = snapshot
        self.delta = delta
        self.snapshotMeta = snapshotMeta
        self.snapshotMessages = snapshotMessages
    }

    /// Parse a daemon notification into a SubscriptionPush, or nil if it isn't one.
    /// Chat-channel payloads are decoded into typed values here so the caller's
    /// isolation domain (off-main in the live frame pump) pays the decode cost.
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
                    snapshotMeta: meta,
                    snapshotMessages: messages.compactMap { ConversationMessage.parseMessage($0) }
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
            let delta = DeltaPayload(
                added: added, updated: updated, removedIds: removedIds,
                chatBlocks: DeltaPayload.decodeChatBlocks(added: added, updated: updated))
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

    /// Insert or update an already-normalized value without touching sequence
    /// tracking (e.g. an optimistic row from an RPC response). New ids are
    /// placed at the front; existing ids keep their position.
    func seed(id: String, value: T) {
        if items[id] == nil {
            orderedIds.insert(id, at: 0)
        }
        items[id] = value
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
