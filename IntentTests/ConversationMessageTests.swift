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

    /// Formerly divergent: the `Codable` path dropped the whole array (and
    /// reported the blocks as unprovided) on one malformed entry, while the
    /// dictionary path dropped only that entry. Both now drop only the entry,
    /// and the surviving block keeps its wire index.
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

    /// Same former divergence for `toolCalls` / `toolResults`.
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
