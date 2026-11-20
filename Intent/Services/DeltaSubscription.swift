import Foundation

/// `@unchecked Sendable`: the raw dictionaries are parsed JSON containers that are never
/// mutated after parse.
nonisolated struct SubscriptionPush: @unchecked Sendable {
    let subscriptionId: String
    let kind: Kind
    let seq: Int
    let snapshot: [[String: Any]]? // swiftlint:disable:this discouraged_optional_collection
    let nextToken: String?
    let delta: DeltaPayload?
    let snapshotMeta: [String: Any]? // swiftlint:disable:this discouraged_optional_collection
    let snapshotMessages: [ConversationMessage]? // swiftlint:disable:this discouraged_optional_collection

    enum Kind {
        case snapshot
        case delta
    }

    enum Payload {
        case collectionSnapshot([[String: Any]])
        case conversationSnapshot(rows: [[String: Any]], metadata: [String: Any])
        case delta(DeltaPayload)
    }

    var payload: Payload {
        if let delta { return .delta(delta) }
        let rows = snapshot ?? []
        if let snapshotMeta {
            return .conversationSnapshot(rows: rows, metadata: snapshotMeta)
        }
        return .collectionSnapshot(rows)
    }

    struct ChatBlockEntity {
        let messageId: String
        let appMessageId: String?
        let block: ContentBlock
        let textDelta: String?
        let role: MessageRole
        let timestamp: String?
        let streamingComplete: Bool
        let metadata: [String: AnyCodable]

        init?(entity: [String: Any]) {
            guard let shaped = ShapedChatBlockEntity(entity: entity),
                  let block = ContentBlock.decode(shaped.block, fallbackIdentity: shaped.fallbackIdentity)
            else {
                return nil
            }
            self.init(shaped: shaped, block: block)
        }

        private init(shaped: ShapedChatBlockEntity, block: ContentBlock) {
            messageId = shaped.messageId
            appMessageId = shaped.entity["appMessageId"] as? String
            self.block = block
            textDelta = shaped.textDelta
            role = MessageRole(rawValue: shaped.entity["role"] as? String ?? "assistant") ?? .system
            timestamp = shaped.entity["timestamp"] as? String
            streamingComplete = shaped.entity["streamingComplete"] as? Bool ?? false
            metadata = Self.decodeMetadata(shaped.entity["metadata"])
        }

        private static func decodeMetadata(_ value: Any?) -> [String: AnyCodable] {
            guard let dictionary = value as? [String: Any], !dictionary.isEmpty,
                  JSONSerialization.isValidJSONObject(dictionary),
                  let data = try? JSONSerialization.data(withJSONObject: dictionary) else { return [:] }
            return (try? JSONDecoder().decode([String: AnyCodable].self, from: data)) ?? [:]
        }

        static func decodeAll(_ entities: [[String: Any]]) -> [Self] {
            let shaped = entities.compactMap { ShapedChatBlockEntity(entity: $0) }
            let blocks = ContentBlock.decodeBatch(
                shaped.map(\.block),
                fallbackIdentities: shaped.map(\.fallbackIdentity)
            )
            return zip(shaped, blocks).compactMap { entry, block in
                block.map { Self(shaped: entry, block: $0) }
            }
        }
    }

    private struct ShapedChatBlockEntity {
        let entity: [String: Any]
        let messageId: String
        let block: [String: Any]
        let textDelta: String?

        var fallbackIdentity: ContentBlock.FallbackIdentity { .fingerprint(messageId: messageId) }

        init?(entity: [String: Any]) {
            guard let messageId = entity["messageId"] as? String,
                  let block = entity["block"] as? [String: Any] else { return nil }
            let type = block["type"] as? String
            if type == "text" || type == "thinking", block["textDelta"] != nil {
                if let text = block["text"] ?? block["content"] {
                    guard text is String else { return nil }
                    textDelta = nil
                } else {
                    guard let fragment = block["textDelta"] as? String,
                          let id = block["id"] as? String, !id.isEmpty else { return nil }
                    textDelta = fragment
                }
            } else {
                textDelta = nil
            }
            self.entity = entity
            self.messageId = messageId
            self.block = block
        }
    }

    struct DeltaPayload {
        let added: [[String: Any]]
        let updated: [[String: Any]]
        let removedIds: [String]
        let chatBlocks: [ChatBlockEntity]? // swiftlint:disable:this discouraged_optional_collection

        init(
            added: [[String: Any]],
            updated: [[String: Any]],
            removedIds: [String],
            chatBlocks: [ChatBlockEntity]? = nil // swiftlint:disable:this discouraged_optional_collection
        ) {
            self.added = added
            self.updated = updated
            self.removedIds = removedIds
            self.chatBlocks = chatBlocks
        }

        // swiftlint:disable:next discouraged_optional_collection
        static func decodeChatBlocks(added: [[String: Any]], updated: [[String: Any]]) -> [ChatBlockEntity]? {
            let entities = added + updated
            guard entities.contains(where: { $0["block"] is [String: Any] }) else { return nil }
            return ChatBlockEntity.decodeAll(entities)
        }
    }

    init(
        subscriptionId: String,
        kind: Kind,
        seq: Int,
        snapshot: [[String: Any]]?, // swiftlint:disable:this discouraged_optional_collection
        delta: DeltaPayload?,
        snapshotMeta: [String: Any]? = nil, // swiftlint:disable:this discouraged_optional_collection
        snapshotMessages: [ConversationMessage]? = nil, // swiftlint:disable:this discouraged_optional_collection
        nextToken: String? = nil
    ) {
        self.subscriptionId = subscriptionId
        self.kind = kind
        self.seq = seq
        self.snapshot = snapshot
        self.nextToken = nextToken
        self.delta = delta
        self.snapshotMeta = snapshotMeta
        self.snapshotMessages = snapshotMessages
    }

    init(subscriptionId: String, seq: Int, snapshot: [[String: Any]], nextToken: String? = nil) {
        self.init(
            subscriptionId: subscriptionId,
            kind: .snapshot,
            seq: seq,
            snapshot: snapshot,
            delta: nil,
            nextToken: nextToken
        )
    }

    init(
        subscriptionId: String,
        seq: Int,
        conversationSnapshot: [[String: Any]],
        metadata: [String: Any]
    ) {
        self.init(
            subscriptionId: subscriptionId,
            kind: .snapshot,
            seq: seq,
            snapshot: conversationSnapshot,
            delta: nil,
            snapshotMeta: metadata,
            snapshotMessages: ConversationMessage.parseMessages(conversationSnapshot)
        )
    }

    init(subscriptionId: String, seq: Int, delta: DeltaPayload) {
        self.init(
            subscriptionId: subscriptionId,
            kind: .delta,
            seq: seq,
            snapshot: nil,
            delta: delta
        )
    }

    static func parse(method: String, params: Any) -> Self? {
        guard method == "subscription.push",
              let dict = params as? [String: Any],
              let subscriptionId = dict["subscriptionId"] as? String,
              let seq = dict["seq"] as? Int else {
            return nil
        }

        if dict["kind"] as? String == "snapshot" {
            return parseSnapshot(dict: dict, subscriptionId: subscriptionId, seq: seq)
        }
        guard dict["kind"] as? String == "delta",
              let deltaDict = dict["delta"] as? [String: Any] else {
            return nil
        }
        let added = (deltaDict["added"] as? [[String: Any]]) ?? []
        let updated = (deltaDict["updated"] as? [[String: Any]]) ?? []
        let removedIds = (deltaDict["removedIds"] as? [String]) ?? []
        let delta = DeltaPayload(
            added: added,
            updated: updated,
            removedIds: removedIds,
            chatBlocks: DeltaPayload.decodeChatBlocks(added: added, updated: updated)
        )
        return Self(
            subscriptionId: subscriptionId,
            kind: .delta,
            seq: seq,
            snapshot: nil,
            delta: delta
        )
    }

    private static func parseSnapshot(
        dict: [String: Any],
        subscriptionId: String,
        seq: Int
    ) -> Self? {
        if let snapshot = dict["snapshot"] as? [[String: Any]] {
            let token = dict["nextToken"] as? String
            return Self(
                subscriptionId: subscriptionId,
                kind: .snapshot,
                seq: seq,
                snapshot: snapshot,
                delta: nil,
                nextToken: token?.isEmpty == false ? token : nil
            )
        }
        guard let snapshotObject = dict["snapshot"] as? [String: Any],
              let messages = snapshotObject["messages"] as? [[String: Any]] else {
            return nil
        }
        var metadata = snapshotObject
        metadata.removeValue(forKey: "messages")
        return Self(
            subscriptionId: subscriptionId,
            kind: .snapshot,
            seq: seq,
            snapshot: messages,
            delta: nil,
            snapshotMeta: metadata,
            snapshotMessages: ConversationMessage.parseMessages(messages)
        )
    }
}

class DeltaReconciler<T> {
    private var items = [String: T]()
    private var orderedIds = [String]()
    private var expectedSeq = 0
    private var seeded = false
    private var changedSinceSnapshot = Set<String>()
    private var removedSinceSnapshot = Set<String>()
    private(set) var epoch = 0

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

    func reset() {
        items.removeAll()
        orderedIds.removeAll()
        changedSinceSnapshot.removeAll()
        removedSinceSnapshot.removeAll()
        expectedSeq = 0
        seeded = false
        epoch &+= 1
    }

    func applySnapshot(seq: Int, rawItems: [[String: Any]]) {
        items.removeAll()
        orderedIds.removeAll()
        changedSinceSnapshot.removeAll()
        removedSinceSnapshot.removeAll()
        epoch &+= 1
        for raw in rawItems {
            upsert(raw)
        }
        expectedSeq = seq + 1
        seeded = true
    }

    func applyDelta(seq: Int, delta: SubscriptionPush.DeltaPayload) -> Bool {
        guard seeded, seq == expectedSeq else {
            return false
        }
        for raw in delta.added + delta.updated {
            if let id = upsert(raw) { changedSinceSnapshot.insert(id) }
        }
        for id in delta.removedIds {
            items.removeValue(forKey: id)
            orderedIds.removeAll { $0 == id }
            removedSinceSnapshot.insert(id)
        }
        expectedSeq = seq + 1
        return true
    }

    func values() -> [T] {
        orderedIds.compactMap { items[$0] }
    }

    func seed(id: String, value: T) {
        if items[id] == nil {
            orderedIds.insert(id, at: 0)
        }
        items[id] = value
        changedSinceSnapshot.insert(id)
    }

    func patch(id: String, _ transform: (T) -> T) {
        guard let current = items[id] else { return }
        items[id] = transform(current)
        changedSinceSnapshot.insert(id)
    }

    func fillFromPage(_ rawItems: [[String: Any]]) {
        for raw in rawItems {
            guard let id = getId(raw),
                  !changedSinceSnapshot.contains(id),
                  !removedSinceSnapshot.contains(id) else { continue }
            upsert(raw)
        }
    }

    @discardableResult
    private func upsert(_ raw: [String: Any]) -> String? {
        guard let id = getId(raw), let normalized = normalize(raw) else {
            return nil
        }
        if items[id] == nil {
            orderedIds.append(id)
        }
        items[id] = normalized
        return id
    }
}
