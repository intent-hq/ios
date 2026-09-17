import Foundation
@testable import Intent
import Testing

// MARK: - AnyCodable Tests

struct AnyCodableTests {
    private func isArrayValue(_ match: AnyCodableArrayMatch) -> Bool {
        if case .value = match { true } else { false }
    }

    private func isDictionaryValue(_ match: AnyCodableDictionaryMatch) -> Bool {
        if case .value = match { true } else { false }
    }

    private func isTypeMismatch(_ match: AnyCodableArrayMatch) -> Bool {
        if case .typeMismatch = match { true } else { false }
    }

    private func isTypeMismatch(_ match: AnyCodableDictionaryMatch) -> Bool {
        if case .typeMismatch = match { true } else { false }
    }

    @Test func encodeDecodeString() throws {
        let original = AnyCodable("hello")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.stringValue == "hello")
    }

    @Test func encodeDecodeInt() throws {
        let original = AnyCodable(42)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.intValue == 42)
    }

    @Test func encodeDecodeDouble() throws {
        let original = AnyCodable(3.14)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.doubleValue == 3.14)
    }

    @Test func encodeDecodeBool() throws {
        let original = AnyCodable(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.boolValue == .value(true))
    }

    @Test func encodeDecodeArray() throws {
        let original = AnyCodable([1, 2, 3])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let match = decoded.arrayValue
        #expect(isArrayValue(match))
        guard case let .value(arr) = match else { return }
        #expect(arr.count == 3)
    }

    @Test func encodeDecodeDictionary() throws {
        let original = AnyCodable(["key": "value"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let match = decoded.dictValue
        #expect(isDictionaryValue(match))
        guard case let .value(dict) = match else { return }
        #expect(dict["key"] as? String == "value")
    }

    @Test func encodeDecodeNil() throws {
        let original = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.isNull)
    }

    @Test func equality() {
        let first = AnyCodable("test")
        let matching = AnyCodable("test")
        let different = AnyCodable("other")
        #expect(first == matching)
        #expect(first != different)
    }

    @Test func convenienceAccessorsReportWrongType() {
        let str = AnyCodable("hello")
        #expect(str.intValue == nil)
        #expect(str.boolValue == .typeMismatch)
        #expect(str.doubleValue == nil)
        #expect(isTypeMismatch(str.arrayValue))
        #expect(isTypeMismatch(str.dictValue))
        #expect(str.isNull == false)
    }
}

// MARK: - ContentBlock Tests

struct QuestionsDismissedNoticeTests {
    private let noticeText = "User dismissed your 2 questions without answering."

    @Test func classifiesFromRowMetadata() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": [
                "type": "questions_dismissed",
                "source": "system",
                "dismissedQuestionsMessageId": "a1"
            ] as [String: Any]
        ]))
        let notice = try #require(msg.questionsDismissedNotice)
        #expect(notice.dismissedQuestionsMessageId == "a1")
        #expect(notice.fullText == noticeText)
    }

    @Test func classifiesFromBlockMessageMetadataFallback() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [
                [
                    "type": "text",
                    "text": noticeText,
                    "messageMetadata": [
                        "type": "questions_dismissed",
                        "dismissedQuestionsMessageId": "a1"
                    ] as [String: Any]
                ]
            ]
        ]))
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId == "a1")
    }

    @Test func toleratesAnyRole() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "system",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": ["type": "questions_dismissed"] as [String: Any]
        ]))
        #expect(msg.questionsDismissedNotice != nil)
    }

    @Test func missingDismissedIdReadsAsEmpty() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": ["type": "questions_dismissed"] as [String: Any]
        ]))
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId.isEmpty == true)
    }

    @Test func otherMetadataTypesReturnNil() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [["type": "text", "text": "hello"]],
            "metadata": ["type": "question_answers"] as [String: Any]
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func plainMessagesReturnNil() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [["type": "text", "text": "hello"]]
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func nonTextBlockMetadataIsIgnored() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d",
            "role": "user",
            "contentBlocks": [
                [
                    "type": "tool_use",
                    "name": "t",
                    "messageMetadata": ["type": "questions_dismissed"] as [String: Any]
                ]
            ]
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func classifiesAfterCodableRoundTrip() throws {
        let json = """
        {"id":"msg-d","role":"user","timestamp":"2026-08-09T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"User dismissed your 1 question without answering.",
           "messageMetadata":{"type":"questions_dismissed","dismissedQuestionsMessageId":"a1"}}]}
        """
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId == "a1")
    }
}

// MARK: - ConversationMessage Tests

struct ConversationMessageTests {
    @Test func parseMessageFull() {
        let dict: [String: Any] = [
            "id": "msg-1",
            "role": "assistant",
            "timestamp": "2025-01-01T00:00:00Z",
            "turnNumber": 3,
            "isStreaming": true,
            "error": "some error",
            "contentBlocks": [
                ["type": "text", "text": "Hello"]
            ],
            "toolCalls": [
                ["id": "tc-1", "name": "read_file", "status": "completed"]
            ],
            "toolResults": [
                ["toolCallId": "tc-1", "isError": false]
            ],
            "metadata": ["key": "value"]
        ]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg != nil)
        #expect(msg?.id == "msg-1")
        #expect(msg?.role == .assistant)
        #expect(msg?.timestamp == "2025-01-01T00:00:00Z")
        #expect(msg?.turnNumber == 3)
        #expect(msg?.isStreaming == true)
        #expect(msg?.error == "some error")
        #expect(msg?.contentBlocks.count == 1)
        #expect(msg?.contentBlocks.first?.resolvedText == "Hello")
        #expect(msg?.toolCalls.count == 1)
        #expect(msg?.toolCalls.first?.name == "read_file")
        #expect(msg?.toolResults.count == 1)
        #expect(msg?.metadata["key"]?.stringValue == "value")
    }

    @Test func parseMessageMinimal() {
        let dict: [String: Any] = [
            "id": "msg-2",
            "role": "user"
        ]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg != nil)
        #expect(msg?.id == "msg-2")
        #expect(msg?.role == .user)
        #expect(msg?.timestamp.isEmpty == true)
        #expect(msg?.contentBlocks.isEmpty == true)
        #expect(msg?.hasReportedContentBlocks == false)
        #expect(msg?.toolCalls.isEmpty == true)
        #expect(msg?.hasReportedToolCalls == false)
        #expect(msg?.streamingState == .unreported)
    }

    @Test func parseMessageMissingIdReturnsNil() {
        let dict: [String: Any] = ["role": "user"]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg == nil)
    }

    @Test func parseMessageUnknownRoleDefaultsToSystem() {
        let dict: [String: Any] = [
            "id": "msg-3",
            "role": "unknown_role"
        ]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg?.role == .system)
    }

    @Test func codableRoundTrip() throws {
        let original = ConversationMessage(
            id: "msg-rt",
            role: .user,
            contentBlocks: [ContentBlock(type: .text, text: "test")],
            timestamp: "2025-01-01T00:00:00Z",
            turnNumber: 1,
            streamingState: .complete
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(decoded.id == "msg-rt")
        #expect(decoded.role == .user)
        #expect(decoded.contentBlocks.first?.resolvedText == "test")
        #expect(decoded.turnNumber == 1)
    }

    /// Transcript rows compare messages by value (`MessageRowContent`): equal
    /// content must compare equal, and any changed block must not.
    @Test func equalityTracksContentBlockChanges() {
        let base = ConversationMessage(
            id: "msg-eq",
            role: .assistant,
            contentBlocks: [
                ContentBlock(id: "b1", type: .text, text: "Hello"),
                ContentBlock(
                    id: "b2",
                    type: .toolUse,
                    name: "read_file",
                    input: ["path": AnyCodable("a.txt")]
                )
            ],
            timestamp: "2025-01-01T00:00:00Z",
            streamingState: .streaming
        )
        var same = base
        same.contentBlocks = [
            ContentBlock(id: "b1", type: .text, text: "Hello"),
            ContentBlock(
                id: "b2",
                type: .toolUse,
                name: "read_file",
                input: ["path": AnyCodable("a.txt")]
            )
        ]
        #expect(base == same)

        var textDelta = base
        textDelta.contentBlocks[0].text = "Hello, world"
        #expect(base != textDelta)

        var inputChanged = base
        inputChanged.contentBlocks[1].input = ["path": AnyCodable("b.txt")]
        #expect(base != inputChanged)

        var appended = base
        appended.contentBlocks.append(ContentBlock(id: "b3", type: .text, text: "more"))
        #expect(base != appended)

        var finished = base
        finished.isStreaming = false
        #expect(base != finished)
    }
}

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
    @Test func parseMessagesMatchesPerRowParseIncludingMalformedRows() throws {
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
    @Test func parseMessagesFallsBackPerRowWhenPageIsNotSerializable() throws {
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
    @Test func decodeBatchMatchesPerItemDecode() throws {
        let dicts: [[String: Any]] = [
            ["type": "text", "text": "a"],
            ["id": "wire-1", "type": "text", "text": "b"],
            ["type": "tool_result", "toolUseId": "tc-1", "output": "full"],
            ["type": "text", "text": "d"]
        ]
        let identities: [ContentBlock.FallbackIdentity] = [
            .fingerprint(messageId: "m-a"), .indexed(messageId: "m-b", index: 4), .fixed("msg-1:3"), .indexed(messageId: "m-d", index: 0)
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
        #expect(ContentBlock.decodeBatch([], fallbackIdentities: []).isEmpty)
    }

    /// ios#258: an element with a non-finite number makes the batch
    /// un-serializable; each element is then decoded on its own, so that
    /// element alone is nil and the others keep their identities. The per-item
    /// `decode` must return nil for it rather than trap in `JSONSerialization`.
    @Test func decodeBatchFallsBackPerItemWhenBatchIsNotSerializable() throws {
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

// MARK: - QueuedMessage Tests

struct QueuedMessageTests {
    @Test func initAndCodable() throws {
        let msg = QueuedMessage(id: "q-1", content: "hello", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: data)
        #expect(decoded.id == "q-1")
        #expect(decoded.content == "hello")
        #expect(decoded.queuedAt == "2025-01-01T00:00:00Z")
        #expect(decoded.position == 0)
        #expect(decoded.imageBlocks.isEmpty)
        #expect(!decoded.hasReportedImageBlocks)
    }

    @Test func withImageBlocks() throws {
        let img = ImageBlock(type: "image", data: "abc123", mimeType: "image/jpeg")
        let msg = QueuedMessage(id: "q-2", content: "see image", queuedAt: "2025-01-01T00:00:00Z", position: 1, imageBlocks: [img])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: data)
        #expect(decoded.imageBlocks.count == 1)
        #expect(decoded.imageBlocks.first?.mimeType == "image/jpeg")
        #expect(decoded.imageBlocks.first?.data == "abc123")
    }

    @Test func imageBlockReferenceArmOmitsDataKey() throws {
        // Attachment-registry reference (PROTOCOL §5.5, monorepo#3338):
        // encodes attachmentId and never emits a "data" key.
        let img = ImageBlock(type: "image", attachmentId: "att-9", mimeType: "image/jpeg")
        let encoded = try JSONEncoder().encode(img)
        let json = try #require(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        #expect(json["attachmentId"] as? String == "att-9")
        #expect(json["data"] == nil)

        let decoded = try JSONDecoder().decode(ImageBlock.self, from: encoded)
        #expect(decoded.attachmentId == "att-9")
        #expect(decoded.data == nil)
    }

    @Test func decodesImageReferenceWithoutMimeType() throws {
        // The wire reference arm is { type, attachmentId, mimeType? }
        // (PROTOCOL §5.5) — a spec-legal entry without mimeType (e.g.
        // authored by another client) must not fail the element decode,
        // which would blank the whole [QueuedMessage] queue view.
        let json = """
        {"id": "q-3", "content": "img", "queuedAt": "2025-01-01T00:00:00Z", "position": 0, \
        "imageBlocks": [{"type": "image", "attachmentId": "att-9"}]}
        """
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(decoded.imageBlocks.count == 1)
        #expect(decoded.imageBlocks.first?.attachmentId == "att-9")
        #expect(decoded.imageBlocks.first?.mimeType == nil)
    }

    @Test func decodesWithoutMessageMetadata() throws {
        // Backward compat: wire entries without messageMetadata must decode.
        let json = """
        {"id": "q-1", "content": "hello", "queuedAt": "2025-01-01T00:00:00Z", "position": 0}
        """
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(decoded.messageMetadata.isEmpty)
        #expect(!decoded.hasReportedMessageMetadata)
        #expect(decoded.isUserMessage)
    }

    @Test func decodesWithMessageMetadata() throws {
        let json = """
        {"id": "q-1", "content": "wake", "queuedAt": "2025-01-01T00:00:00Z", "position": 0, \
        "messageMetadata": {"type": "agent_message", "fromAgentId": "agent-2"}}
        """
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(decoded.messageMetadata["type"]?.stringValue == "agent_message")
        #expect(decoded.messageMetadata["fromAgentId"]?.stringValue == "agent-2")
    }

    // MARK: isUserMessage predicate (shared with FE, see spec Background)

    private func queued(metadata: [String: AnyCodable] = [:]) -> QueuedMessage {
        QueuedMessage(
            id: "q",
            content: "c",
            queuedAt: "2025-01-01T00:00:00Z",
            position: 0,
            messageMetadata: metadata
        )
    }

    @Test func isUserMessageTrueWithoutMetadata() {
        #expect(queued().isUserMessage)
    }

    @Test func isUserMessageTrueWithBenignMetadata() {
        #expect(queued(metadata: [
            "userAppMessageId": AnyCodable("uam-1"),
            "queueInfo": AnyCodable(["position": 1])
        ]).isUserMessage)
    }

    @Test func isUserMessageFalseWithTypeString() {
        for type in ["agent_message", "event_notification", "hook_wake", "task_wake", "questions_dismissed"] {
            #expect(!queued(metadata: ["type": AnyCodable(type)]).isUserMessage)
        }
    }

    @Test func isUserMessageTrueWithQuestionAnswersType() {
        // The Q&A wizard's auto-queued answer entry is user-authored despite
        // carrying a string `type` (fe parity, cloudlands-fe #1167).
        #expect(queued(metadata: [
            "type": AnyCodable("question_answers"),
            "answeredQuestionsMessageId": AnyCodable("qm-1")
        ]).isUserMessage)
    }

    @Test func isUserMessageQuestionAnswersExemptionPrecedesOtherRules() {
        // Matches fe ordering: the question_answers exemption returns early,
        // before the fromAgentId and source hide rules.
        #expect(queued(metadata: [
            "type": AnyCodable("question_answers"),
            "fromAgentId": AnyCodable("agent-2"),
            "source": AnyCodable("system")
        ]).isUserMessage)
    }

    @Test func isUserMessageFalseWithFromAgentId() {
        #expect(!queued(metadata: ["fromAgentId": AnyCodable("agent-2")]).isUserMessage)
    }

    @Test func isUserMessageTrueWithEmptyFromAgentId() {
        #expect(queued(metadata: ["fromAgentId": AnyCodable("")]).isUserMessage)
    }

    @Test func isUserMessageTrueWithWhitespaceOnlyFromAgentId() {
        // fe parity: `isUserQueuedMessage` trims `fromAgentId` before its
        // non-empty check, so a whitespace-only value is treated as absent.
        #expect(queued(metadata: ["fromAgentId": AnyCodable("   ")]).isUserMessage)
        #expect(queued(metadata: ["fromAgentId": AnyCodable("\t\n")]).isUserMessage)
    }

    @Test func isUserMessageFalseWithSystemSource() {
        #expect(!queued(metadata: ["source": AnyCodable("system")]).isUserMessage)
    }

    @Test func isUserMessageTrueWithNonSystemSource() {
        #expect(queued(metadata: ["source": AnyCodable("other")]).isUserMessage)
    }

    @Test func isUserMessageTrueWithNonStringMarkers() {
        // Malformed marker values fail open.
        #expect(queued(metadata: [
            "type": AnyCodable(42),
            "fromAgentId": AnyCodable(true)
        ]).isUserMessage)
    }
}
