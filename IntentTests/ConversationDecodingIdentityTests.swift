import Foundation
@testable import Intent
import Testing

// MARK: - Unified decoding + stable block identity (ios#257)

/// One decoder for every path, and one identity policy for blocks served
/// without a wire `id`: `{messageId}:{index}` inside a message (the daemon's
/// own PROTOCOL §7.1 synthetic id), a message-scoped content fingerprint for a
/// standalone block, the requested id for a hydrated block.
struct ConversationDecodingIdentityTests {
    private let row: [String: Any] = [
        "id": "msg-1",
        "role": "assistant",
        "contentBlocks": [
            ["type": "text", "text": "Hello"],
            ["type": "tool_use", "name": "read_file", "input": ["path": "a.txt"]],
            ["id": "wire-2", "type": "text", "text": "kept"]
        ]
    ]

    private func rowData(_ dict: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: dict)
    }

    @Test func parseMessageKeysIdLessBlocksByMessageIdAndIndex() throws {
        let msg = try #require(ConversationMessage.parseMessage(row))
        #expect(msg.contentBlocks.map(\.id) == ["msg-1:0", "msg-1:1", "wire-2"])
    }

    @Test func sameRowDecodedTwiceYieldsIdenticalBlockIds() throws {
        let first = try #require(ConversationMessage.parseMessage(row))
        let second = try #require(ConversationMessage.parseMessage(row))
        #expect(first == second)
        #expect(first.contentBlocks.map(\.id) == second.contentBlocks.map(\.id))

        let data = try rowData(row)
        let codableFirst = try JSONDecoder().decode(ConversationMessage.self, from: data)
        let codableSecond = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(codableFirst == codableSecond)
    }

    @Test func codableAndDictionaryPathsAgree() throws {
        let viaDictionary = try #require(ConversationMessage.parseMessage(row))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(row))
        #expect(viaDictionary == viaCodable)
        #expect(viaCodable.contentBlocks.map(\.id) == ["msg-1:0", "msg-1:1", "wire-2"])
    }

    @Test func transcriptAppMessageIdSurvivesEveryDecodePathAndRoundTrip() throws {
        let wire: [String: Any] = [
            "id": "server-drained-row", "appMessageId": "client-attempt", "role": "user",
            "contentBlocks": [["type": "text", "text": "hello"]]
        ]
        let viaDictionary = try #require(ConversationMessage.parseMessage(wire))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(wire))
        let viaPage = try #require(ConversationMessage.parseMessages([wire]).first)
        for message in [viaDictionary, viaCodable, viaPage] {
            #expect(message.id == "server-drained-row")
            #expect(message.appMessageId == "client-attempt")
            #expect(message.metadata.isEmpty, "correlation is top-level, not fabricated metadata")
            let encoded = try JSONEncoder().encode(message)
            let fields = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            #expect(fields["appMessageId"] as? String == "client-attempt")
            #expect(fields["metadata"] == nil)
            #expect(try JSONDecoder().decode(ConversationMessage.self, from: encoded) == message)
        }
    }

    @Test func missingOrMalformedAppMessageIdRemainsOptional() throws {
        for value: Any in [NSNull(), 42, ["nested": "not-an-id"]] {
            var wire = row
            wire["appMessageId"] = value
            let message = try #require(ConversationMessage.parseMessage(wire))
            #expect(message.appMessageId == nil)
        }
        let message = try #require(ConversationMessage.parseMessage(row))
        #expect(message.appMessageId == nil)
        let fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
        #expect(fields["appMessageId"] == nil, "legacy rows do not gain a null correlation field")
    }

    @Test func idLessBlocksOfDifferentMessagesDoNotCollide() throws {
        var other = row
        other["id"] = "msg-2"
        let first = try #require(ConversationMessage.parseMessage(row))
        let second = try #require(ConversationMessage.parseMessage(other))
        #expect(first.contentBlocks.map(\.id).prefix(2) == ["msg-1:0", "msg-1:1"])
        #expect(second.contentBlocks.map(\.id).prefix(2) == ["msg-2:0", "msg-2:1"])
    }

    /// Formerly divergent: an all-dictionary array with one entry missing its
    /// required key (`ToolCall.id` / `ToolResult.toolCallId`). The dictionary
    /// path decoded per element and kept the sibling (reported as provided);
    /// the `Codable` path decoded the whole array, dropped it, and reported
    /// the collection as unprovided. Both now keep the sibling.
    @Test func toolEntryMissingRequiredKeyDropsOnlyThatEntryOnBothPaths() throws {
        let dict: [String: Any] = [
            "id": "msg-6",
            "role": "assistant",
            "toolCalls": [
                ["name": "read_file", "status": "completed"],
                ["id": "tc-1", "name": "read_file", "status": "completed"]
            ],
            "toolResults": [
                ["toolCallId": "tc-1", "isError": false],
                ["isError": true, "content": "orphan"]
            ]
        ]
        let viaDictionary = try #require(ConversationMessage.parseMessage(dict))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(dict))
        for msg in [viaDictionary, viaCodable] {
            #expect(msg.hasReportedToolCalls)
            #expect(msg.toolCalls.map(\.id) == ["tc-1"])
            #expect(msg.hasReportedToolResults)
            #expect(msg.toolResults.map(\.toolCallId) == ["tc-1"])
        }
        #expect(viaDictionary == viaCodable)
    }

    /// A mixed array (non-object entry) was dropped whole by BOTH old paths
    /// (`as? [[String: Any]]` and `decode([ContentBlock].self)` both fail),
    /// which also read it as unprovided. The unified decoder keeps the object
    /// siblings and reports the collection as provided; the surviving block
    /// keeps its wire index. (A block that IS an object never fails to decode
    /// — every `ContentBlock` field is lenient — so this is the only malformed
    /// block shape.)
    @Test func malformedBlockEntryDropsOnlyThatEntryOnBothPaths() throws {
        let dict: [String: Any] = [
            "id": "msg-3",
            "role": "user",
            "contentBlocks": ["not-a-block", ["type": "text", "text": "kept"]]
        ]
        let viaDictionary = try #require(ConversationMessage.parseMessage(dict))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(dict))
        for msg in [viaDictionary, viaCodable] {
            #expect(msg.hasReportedContentBlocks)
            #expect(msg.contentBlocks.count == 1)
            #expect(msg.contentBlocks.first?.resolvedText == "kept")
            #expect(msg.contentBlocks.first?.id == "msg-3:1")
        }
        #expect(viaDictionary == viaCodable)
    }

    /// Same mixed-array shape for `toolCalls` / `toolResults`: formerly
    /// dropped whole by both paths, now keeps the object siblings.
    @Test func malformedToolEntriesDropOnlyThatEntryOnBothPaths() throws {
        let dict: [String: Any] = [
            "id": "msg-4",
            "role": "assistant",
            "toolCalls": [42, ["id": "tc-1", "name": "read_file", "status": "completed"]],
            "toolResults": [["toolCallId": "tc-1", "isError": false], NSNull()]
        ]
        let viaDictionary = try #require(ConversationMessage.parseMessage(dict))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(dict))
        for msg in [viaDictionary, viaCodable] {
            #expect(msg.hasReportedToolCalls)
            #expect(msg.toolCalls.map(\.id) == ["tc-1"])
            #expect(msg.hasReportedToolResults)
            #expect(msg.toolResults.count == 1)
        }
        #expect(viaDictionary == viaCodable)
    }

    @Test func nonArrayCollectionsReadAsUnprovidedOnBothPaths() throws {
        let dict: [String: Any] = ["id": "msg-5", "role": "user", "contentBlocks": NSNull(), "toolCalls": "nope"]
        let viaDictionary = try #require(ConversationMessage.parseMessage(dict))
        let viaCodable = try JSONDecoder().decode(ConversationMessage.self, from: rowData(dict))
        for msg in [viaDictionary, viaCodable] {
            #expect(!msg.hasReportedContentBlocks)
            #expect(!msg.hasReportedToolCalls)
        }
        #expect(viaDictionary == viaCodable)
    }

    @Test func standaloneBlockDecodeIsDeterministicAndContentKeyed() throws {
        let dict: [String: Any] = ["type": "text", "text": "Hello"]
        let first = try #require(ContentBlock.decode(dict))
        let second = try #require(ContentBlock.decode(dict))
        #expect(first.id == second.id)
        #expect(!first.id.isEmpty)

        let json = Data(#"{"type":"text","text":"Hello"}"#.utf8)
        let codableFirst = try JSONDecoder().decode(ContentBlock.self, from: json)
        let codableSecond = try JSONDecoder().decode(ContentBlock.self, from: json)
        #expect(codableFirst.id == codableSecond.id)
        #expect(codableFirst.id == first.id)

        let changed = try #require(ContentBlock.decode(["type": "text", "text": "Hello!"]))
        #expect(changed.id != first.id)
        let otherType = try #require(ContentBlock.decode(["type": "thinking", "text": "Hello"]))
        #expect(otherType.id != first.id)
    }

    @Test func wireIdAlwaysWins() throws {
        let block = try #require(ContentBlock.decode(
            ["id": "wire-9", "type": "text", "text": "x"],
            fallbackIdentity: .indexed(messageId: "m", index: 0)
        ))
        #expect(block.id == "wire-9")
    }

    @Test func deltaEntityIdLessBlockIsStableAndMessageScoped() throws {
        let block: [String: Any] = ["type": "text", "text": "chunk"]
        let entityA: [String: Any] = ["messageId": "msg-a", "block": block]
        let entityB: [String: Any] = ["messageId": "msg-b", "block": block]
        let first = try #require(SubscriptionPush.ChatBlockEntity(entity: entityA))
        let second = try #require(SubscriptionPush.ChatBlockEntity(entity: entityA))
        let other = try #require(SubscriptionPush.ChatBlockEntity(entity: entityB))
        #expect(first.block.id == second.block.id)
        #expect(first.block.id.hasPrefix("msg-a:"))
        #expect(first.block.id != other.block.id)
    }

    /// ios#258: the batched page decoder (one serialization + one decoder per
    /// page, `LenientPage`) must produce exactly what per-row `parseMessage`
    /// produced — dropping the id-less row and continuing with the rows after
    /// it, and keeping the `{messageId}:{index}` block identity. Every row here
    /// is serializable, so this is the single-pass path, not the fallback.
    @Test func parseMessagesMatchesPerRowParseIncludingMalformedRows() {
        var other = row
        other["id"] = "msg-2"
        let idLess: [String: Any] = ["role": "user", "contentBlocks": [["type": "text", "text": "x"]]]
        let malformedBlocks: [String: Any] = [
            "id": "msg-3", "role": "user", "contentBlocks": ["not-a-block", ["type": "text", "text": "kept"]]
        ]
        let rows = [row, idLess, other, malformedBlocks]
        #expect(JSONSerialization.isValidJSONObject(rows))

        let perRow = rows.compactMap { ConversationMessage.parseMessage($0) }
        let batched = ConversationMessage.parseMessages(rows)
        #expect(batched == perRow)
        #expect(batched.map(\.id) == ["msg-1", "msg-2", "msg-3"])
        #expect(batched[0].contentBlocks.map(\.id) == ["msg-1:0", "msg-1:1", "wire-2"])
        #expect(batched[2].contentBlocks.map(\.id) == ["msg-3:1"])
        #expect(ConversationMessage.parseMessages([]).isEmpty)
    }

    /// ios#258: one row with a non-finite number makes the whole page
    /// un-serializable; the page decoder then falls back to per-row decoding
    /// so only that row is dropped, exactly as `parseMessage` drops it.
    @Test func parseMessagesFallsBackPerRowWhenPageIsNotSerializable() {
        var other = row
        other["id"] = "msg-2"
        let nonFinite: [String: Any] = ["id": "msg-nan", "role": "user", "turnNumber": Double.nan]
        let rows = [row, nonFinite, other]
        #expect(!JSONSerialization.isValidJSONObject(rows))

        let batched = ConversationMessage.parseMessages(rows)
        #expect(batched == rows.compactMap { ConversationMessage.parseMessage($0) })
        #expect(batched.map(\.id) == ["msg-1", "msg-2"])
        #expect(batched[0].contentBlocks.map(\.id) == ["msg-1:0", "msg-1:1", "wire-2"])
    }

    /// ios#258: the single-pass block decoder (`ContentBlock.Batch`) carries a
    /// per-element fallback identity positionally and yields the same block
    /// (same id) as the per-item `decode` for every identity kind.
    @Test func decodeBatchMatchesPerItemDecode() {
        let dicts: [[String: Any]] = [
            ["type": "text", "text": "a"],
            ["id": "wire-1", "type": "text", "text": "b"],
            ["type": "tool_result", "toolUseId": "tc-1", "output": "full"],
            ["type": "text", "text": "d"],
            ["type": "text", "text": "a"]
        ]
        let identities: [ContentBlock.FallbackIdentity] = [
            .fingerprint(messageId: "m-a"), .indexed(messageId: "m-b", index: 4),
            .fixed("msg-1:3"), .indexed(messageId: "m-d", index: 0), .fingerprint(messageId: nil)
        ]
        #expect(JSONSerialization.isValidJSONObject(dicts))
        let perItem = zip(dicts, identities).map { ContentBlock.decode($0, fallbackIdentity: $1) }
        let batched = ContentBlock.decodeBatch(dicts, fallbackIdentities: identities)
        #expect(batched.count == dicts.count)
        #expect(batched == perItem)
        #expect(batched[0]?.id.hasPrefix("m-a:") == true)
        #expect(batched[1]?.id == "wire-1")
        #expect(batched[2]?.id == "msg-1:3")
        #expect(batched[3]?.id == "m-d:0")
        #expect(batched[4]?.id.hasPrefix("block:") == true)
        #expect(batched[4] == ContentBlock.decode(dicts[4]))
        #expect(ContentBlock.decodeBatch([], fallbackIdentities: []).isEmpty)
    }

    /// ios#258: an element with a non-finite number makes the batch
    /// un-serializable; each element is then decoded on its own, so that
    /// element alone is nil and the others keep their identities. The per-item
    /// `decode` must return nil for it rather than trap in `JSONSerialization`.
    @Test func decodeBatchFallsBackPerItemWhenBatchIsNotSerializable() {
        let dicts: [[String: Any]] = [
            ["type": "text", "text": "a"],
            ["type": "text", "text": Double.infinity],
            ["id": "wire-1", "type": "text", "text": "b"]
        ]
        let identities: [ContentBlock.FallbackIdentity] = [
            .indexed(messageId: "m-a", index: 2), .fixed("never"), .fixed("unused")
        ]
        #expect(!JSONSerialization.isValidJSONObject(dicts))
        #expect(ContentBlock.decode(dicts[1], fallbackIdentity: .fixed("never")) == nil)

        let batched = ContentBlock.decodeBatch(dicts, fallbackIdentities: identities)
        #expect(batched == zip(dicts, identities).map { ContentBlock.decode($0, fallbackIdentity: $1) })
        #expect(batched.map { $0?.id } == ["m-a:2", nil, "wire-1"])
    }

    /// ios#258: the batched delta decoder yields the same entities, in order,
    /// as decoding each entity on its own; non-block-shaped entities and
    /// entities without a `messageId` are dropped exactly as before, and a
    /// delta with no block-shaped entity stays nil. Every block here is
    /// serializable, so this is the single-pass path.
    @Test func decodeChatBlocksMatchesPerEntityDecode() throws {
        let added: [[String: Any]] = [
            ["messageId": "msg-a", "block": ["type": "text", "text": "chunk"], "streamingComplete": true],
            ["id": "collection-row", "name": "not a block"],
            ["block": ["type": "text", "text": "no message id"]]
        ]
        let updated: [[String: Any]] = [
            ["messageId": "msg-b", "role": "user", "timestamp": "t1", "block": ["id": "wire-7", "type": "text", "text": "x"]],
            ["messageId": "msg-c", "block": ["type": "tool_use", "name": "grep", "input": ["q": "x"]]]
        ]
        let perEntity = (added + updated).compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) }
        let batched = try #require(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: added, updated: updated))
        #expect(batched.count == perEntity.count)
        #expect(batched.map(\.messageId) == ["msg-a", "msg-b", "msg-c"])
        for (lhs, rhs) in zip(batched, perEntity) {
            #expect(lhs.messageId == rhs.messageId)
            #expect(lhs.block == rhs.block)
            #expect(lhs.role == rhs.role)
            #expect(lhs.timestamp == rhs.timestamp)
            #expect(lhs.streamingComplete == rhs.streamingComplete)
        }
        #expect(batched[0].block.id.hasPrefix("msg-a:"))
        #expect(batched[1].block.id == "wire-7")
        #expect(batched[1].role == .user)
        #expect(batched[2].block.id.hasPrefix("msg-c:"))
        #expect(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: [["id": "row"]], updated: []) == nil)
    }

    /// ios#258: a delta whose one block holds a non-finite number takes the
    /// per-entity fallback; only that entity is dropped, the rest match the
    /// per-entity decode.
    @Test func decodeChatBlocksDropsOnlyTheNonSerializableEntity() throws {
        let added: [[String: Any]] = [
            ["messageId": "msg-a", "block": ["type": "text", "text": "chunk"]],
            ["messageId": "msg-nan", "block": ["type": "text", "text": Double.nan]],
            ["messageId": "msg-b", "block": ["id": "wire-7", "type": "text", "text": "x"]]
        ]
        let perEntity = added.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) }
        let batched = try #require(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: added, updated: []))
        #expect(batched.map(\.messageId) == ["msg-a", "msg-b"])
        #expect(batched.map(\.block) == perEntity.map(\.block))
        #expect(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: [added[1]], updated: [])?.isEmpty == true)
    }

    @Test func hydratedBlockWithoutIdKeepsRequestedIdentity() async throws {
        let idLess: [String: Any] = [
            "block": ["type": "tool_result", "toolUseId": "tc-1", "output": "full"]
        ]
        let decoded = await ConversationLiveTranscript.decodeMessageBlock(
            InboundJSONValue(value: idLess),
            blockId: "msg-1:3"
        )
        let block = try #require(decoded)
        #expect(block.id == "msg-1:3")

        let stamped: [String: Any] = [
            "block": ["id": "msg-1:3", "type": "tool_result", "toolUseId": "tc-1", "output": "full"]
        ]
        let decodedStamped = await ConversationLiveTranscript.decodeMessageBlock(
            InboundJSONValue(value: stamped),
            blockId: "other"
        )
        let stampedBlock = try #require(decodedStamped)
        #expect(stampedBlock.id == "msg-1:3")
    }
}
