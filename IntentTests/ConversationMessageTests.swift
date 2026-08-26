import Foundation
import Testing
@testable import Intent

// MARK: - AnyCodable Tests

struct AnyCodableTests {
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
        #expect(decoded.boolValue == true)
    }

    @Test func encodeDecodeArray() throws {
        let original = AnyCodable([1, 2, 3])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let arr = decoded.arrayValue
        #expect(arr != nil)
        #expect(arr?.count == 3)
    }

    @Test func encodeDecodeDictionary() throws {
        let original = AnyCodable(["key": "value"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        let dict = decoded.dictValue
        #expect(dict != nil)
        #expect(dict?["key"] as? String == "value")
    }

    @Test func encodeDecodeNil() throws {
        let original = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        #expect(decoded.isNull)
    }

    @Test func equality() throws {
        let a = AnyCodable("test")
        let b = AnyCodable("test")
        let c = AnyCodable("other")
        #expect(a == b)
        #expect(a != c)
    }

    @Test func convenienceAccessorsReturnNilForWrongType() throws {
        let str = AnyCodable("hello")
        #expect(str.intValue == nil)
        #expect(str.boolValue == nil)
        #expect(str.doubleValue == nil)
        #expect(str.arrayValue == nil)
        #expect(str.dictValue == nil)
        #expect(str.isNull == false)
    }
}

// MARK: - ContentBlock Tests

struct ContentBlockTests {
    @Test func decodeTextBlock() throws {
        let json = #"{"type":"text","text":"Hello world"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .text)
        #expect(block.resolvedText == "Hello world")
        #expect(!block.id.isEmpty) // auto-generated
    }

    @Test func decodeToolUseBlock() throws {
        let json = #"{"type":"tool_use","name":"read_file","input":{"path":"foo.txt"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .toolUse)
        #expect(block.resolvedName == "read_file")
        #expect(block.input != nil)
    }

    @Test func decodeToolResultBlock() throws {
        let json = #"{"type":"tool_result","toolUseId":"tc-1","output":"ok","isError":false}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .toolResult)
        #expect(block.resolvedToolUseId == "tc-1")
        #expect(block.resolvedIsError == false)
    }

    @Test func decodeThinkingBlock() throws {
        let json = #"{"type":"thinking","text":"Let me think..."}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .thinking)
        #expect(block.resolvedText == "Let me think...")
    }

    @Test func decodeImageBlock() throws {
        let json = #"{"type":"image","data":"base64data","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .image)
        #expect(block.data == "base64data")
        #expect(block.mimeType == "image/png")
    }

    @Test func legacyContentFallback() throws {
        let json = #"{"type":"text","content":"legacy text"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.text == nil)
        #expect(block.resolvedText == "legacy text")
    }

    @Test func legacyToolNameFallback() throws {
        let json = #"{"type":"tool_use","toolName":"old_tool"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.name == nil)
        #expect(block.resolvedName == "old_tool")
    }

    @Test func legacyToolUseIdFallback() throws {
        let json = #"{"type":"tool_result","tool_use_id":"tc-legacy"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.toolUseId == nil)
        #expect(block.resolvedToolUseId == "tc-legacy")
    }

    @Test func legacyIsErrorFallback() throws {
        let json = #"{"type":"tool_result","is_error":true}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.isError == nil)
        #expect(block.resolvedIsError == true)
    }

    @Test func unknownTypeDefaultsToText() throws {
        let json = #"{"type":"unknown_type","text":"fallback"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.type == .text)
    }

    @Test func decodeMetaAlias() throws {
        let json = #"{"type":"text","text":"reason","meta":{"kind":"discussion-request"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.metadata == nil)
        #expect(block.resolvedMetadata?["kind"]?.stringValue == "discussion-request")
    }

    @Test func resolvedMetadataPrefersMetadata() throws {
        let json = #"{"type":"text","text":"x","metadata":{"kind":"a"},"meta":{"kind":"b"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: json.data(using: .utf8)!)
        #expect(block.resolvedMetadata?["kind"]?.stringValue == "a")
    }
}

// MARK: - AttentionNotice Tests

struct AttentionNoticeTests {
    private func systemMessage(blocks: [[String: Any]], role: String = "system") -> ConversationMessage? {
        ConversationMessage.parseMessage([
            "id": "msg-att",
            "role": role,
            "contentBlocks": blocks,
        ])
    }

    @Test func classifiesDiscussionRequest() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Need input on the API shape", "meta": ["kind": "discussion-request"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .discussionRequest)
        #expect(notice?.reason == "Need input on the API shape")
    }

    @Test func classifiesBlockerReport() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Sandbox is broken", "meta": ["kind": "blocker-report"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .blockerReport)
        #expect(notice?.reason == "Sandbox is broken")
    }

    @Test func classifiesTurnFailure() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Model refused the request", "meta": ["kind": "turn-failure"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .turnFailure)
        #expect(notice?.reason == "Model refused the request")
    }

    @Test func unknownKindReturnsNil() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Interrupted", "meta": ["kind": "interruption"]]
        ])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func unknownKindFallsBackToJoinedText() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": " Interrupted by restart ", "meta": ["kind": "interruption"]]
        ])
        #expect(msg?.attentionNotice == nil)
        #expect(msg?.joinedTextContent == "Interrupted by restart")
    }

    @Test func joinedTextContentEmptyForNoTextBlocks() throws {
        let msg = systemMessage(blocks: [["type": "tool_use", "name": "some_tool"]])
        #expect(msg?.joinedTextContent == "")
    }

    @Test func missingMetaReturnsNil() throws {
        let msg = systemMessage(blocks: [["type": "text", "text": "plain system message"]])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func nonSystemRoleReturnsNil() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Need input", "meta": ["kind": "discussion-request"]]
        ], role: "assistant")
        #expect(msg?.attentionNotice == nil)
    }

    @Test func emptyContentBlocksReturnsNil() throws {
        let msg = systemMessage(blocks: [])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func nonStringKindReturnsNil() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "x", "meta": ["kind": 42]]
        ])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func reasonJoinsTextBlocksAndTrims() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "  first line ", "meta": ["kind": "blocker-report"]],
            ["type": "tool_use", "name": "some_tool"],
            ["type": "text", "text": "second line"],
        ])
        #expect(msg?.attentionNotice?.reason == "first line \nsecond line")
    }

    @Test func classifiesAfterCodableRoundTrip() throws {
        let json = """
        {"id":"msg-rt","role":"system","timestamp":"2026-07-30T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"Reason","meta":{"kind":"discussion-request"}}]}
        """
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.attentionNotice == AttentionNotice(kind: .discussionRequest, reason: "Reason"))
    }
}

// MARK: - ModelChangeNotice Tests (FE `model-change-notice.ts` parity)

struct ModelChangeNoticeTests {
    private let noticeText = "Model changed from claude-4 to gpt-5."

    private func message(metadata: [String: Any]?, role: String = "system") -> ConversationMessage? {
        var dict: [String: Any] = [
            "id": "msg-mc",
            "role": role,
            "contentBlocks": [["type": "text", "text": noticeText]],
        ]
        if let metadata { dict["metadata"] = metadata }
        return ConversationMessage.parseMessage(dict)
    }

    @Test func classifiesModelChangedRow() throws {
        let msg = message(metadata: [
            "type": "model_changed",
            "from": "claude-4", "to": "gpt-5",
            "fromProvider": "claude-code", "toProvider": "codex",
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(
            from: "claude-4", to: "gpt-5",
            fromProvider: "claude-code", toProvider: "codex"))
    }

    @Test func nullModelIdsMapToNil() throws {
        // `from`/`to` are null for "provider default model" (PROTOCOL §5.5).
        let msg = message(metadata: [
            "type": "model_changed",
            "from": NSNull(), "to": "gpt-5",
            "fromProvider": "claude-code", "toProvider": "codex",
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice.from == nil)
        #expect(notice.to == "gpt-5")
    }

    @Test func missingMetadataReturnsNil() throws {
        #expect(message(metadata: nil)?.modelChangeNotice == nil)
    }

    @Test func otherMetadataTypeReturnsNil() throws {
        #expect(message(metadata: ["type": "questions_dismissed"])?.modelChangeNotice == nil)
    }

    @Test func nonStringTypeReturnsNil() throws {
        #expect(message(metadata: ["type": 42])?.modelChangeNotice == nil)
    }

    @Test func nonStringFieldsAreDroppedNotCrashing() throws {
        let msg = message(metadata: [
            "type": "model_changed",
            "from": 7, "to": ["x": 1], "fromProvider": true,
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(from: nil, to: nil, fromProvider: nil, toProvider: nil))
    }

    @Test func emptyStringFieldsMapToNil() throws {
        // FE parity: asString requires value.length > 0.
        let msg = message(metadata: [
            "type": "model_changed",
            "from": "", "to": "gpt-5", "fromProvider": "", "toProvider": "codex",
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(
            from: nil, to: "gpt-5", fromProvider: nil, toProvider: "codex"))
    }

    @Test func classifiesRegardlessOfRole() throws {
        // FE parity: discriminates purely on metadata.type, tolerant of the
        // exact non-user/non-assistant role the daemon persists.
        let msg = message(metadata: ["type": "model_changed"], role: "model_change")
        #expect(msg?.modelChangeNotice != nil)
        #expect(msg?.role == .system)
    }

    @Test func labelDescribesBothSides() throws {
        let notice = ModelChangeNotice(
            from: "claude-4", to: "gpt-5",
            fromProvider: "claude-code", toProvider: "codex")
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from claude-4 (Claude Code) to gpt-5 (Codex)")
    }

    @Test func labelDescribesProviderDefaultModel() throws {
        let notice = ModelChangeNotice(
            from: nil, to: "gpt-5",
            fromProvider: "claude-code", toProvider: "codex")
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from Claude Code default model to gpt-5 (Codex)")
    }

    @Test func labelWithoutProviderUsesBareModelId() throws {
        let notice = ModelChangeNotice(
            from: "claude-4", to: "gpt-5", fromProvider: nil, toProvider: nil)
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from claude-4 to gpt-5")
    }

    @Test func labelFallsBackToRowTextWhenSideUndescribable() throws {
        let notice = ModelChangeNotice(
            from: nil, to: "gpt-5", fromProvider: nil, toProvider: "codex")
        #expect(notice.label(fallbackText: noticeText) == noticeText)
    }

    @Test func labelFallsBackToGenericWhenRowTextEmpty() throws {
        let notice = ModelChangeNotice(from: nil, to: nil, fromProvider: nil, toProvider: nil)
        #expect(notice.label(fallbackText: "  ") == ModelChangeNotice.fallbackLabel)
    }

    @Test func classifiesAfterCodableRoundTrip() throws {
        let json = """
        {"id":"msg-mc-rt","role":"system","timestamp":"2026-08-22T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"Model changed from a to b."}],
         "metadata":{"type":"model_changed","from":"a","to":"b",
                     "fromProvider":"codex","toProvider":"codex"}}
        """
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.modelChangeNotice == ModelChangeNotice(
            from: "a", to: "b", fromProvider: "codex", toProvider: "codex"))
    }

    @Test func malformedMetadataKeepsAttentionAndBannerPaths() throws {
        // A system row without model_changed metadata still classifies down
        // the existing chain: attention notices stay attention notices, and
        // unclassified rows keep the banner fallback via joinedTextContent.
        let attention = ConversationMessage.parseMessage([
            "id": "msg-a", "role": "system",
            "contentBlocks": [
                ["type": "text", "text": "Need input", "meta": ["kind": "discussion-request"]]
            ],
        ])
        #expect(attention?.modelChangeNotice == nil)
        #expect(attention?.attentionNotice?.kind == .discussionRequest)

        let plain = message(metadata: ["type": "model_change"])
        #expect(plain?.modelChangeNotice == nil)
        #expect(plain?.attentionNotice == nil)
        #expect(plain?.joinedTextContent == noticeText)
    }
}

// MARK: - QuestionsDismissedNotice Tests (FE `questions-dismissed-notice.ts` parity)

struct QuestionsDismissedNoticeTests {
    private let noticeText = "User dismissed your 2 questions without answering."

    @Test func classifiesFromRowMetadata() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": ["type": "questions_dismissed", "source": "system",
                         "dismissedQuestionsMessageId": "a1"] as [String: Any],
        ]))
        let notice = try #require(msg.questionsDismissedNotice)
        #expect(notice.dismissedQuestionsMessageId == "a1")
        #expect(notice.fullText == noticeText)
    }

    @Test func classifiesFromBlockMessageMetadataFallback() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [
                ["type": "text", "text": noticeText,
                 "messageMetadata": ["type": "questions_dismissed",
                                     "dismissedQuestionsMessageId": "a1"] as [String: Any]],
            ],
        ]))
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId == "a1")
    }

    @Test func toleratesAnyRole() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "system",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": ["type": "questions_dismissed"] as [String: Any],
        ]))
        #expect(msg.questionsDismissedNotice != nil)
    }

    @Test func missingDismissedIdReadsAsEmpty() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [["type": "text", "text": noticeText]],
            "metadata": ["type": "questions_dismissed"] as [String: Any],
        ]))
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId == "")
    }

    @Test func otherMetadataTypesReturnNil() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [["type": "text", "text": "hello"]],
            "metadata": ["type": "question_answers"] as [String: Any],
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func plainMessagesReturnNil() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [["type": "text", "text": "hello"]],
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func nonTextBlockMetadataIsIgnored() throws {
        let msg = try #require(ConversationMessage.parseMessage([
            "id": "msg-d", "role": "user",
            "contentBlocks": [
                ["type": "tool_use", "name": "t",
                 "messageMetadata": ["type": "questions_dismissed"] as [String: Any]],
            ],
        ]))
        #expect(msg.questionsDismissedNotice == nil)
    }

    @Test func classifiesAfterCodableRoundTrip() throws {
        let json = """
        {"id":"msg-d","role":"user","timestamp":"2026-08-09T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"User dismissed your 1 question without answering.",
           "messageMetadata":{"type":"questions_dismissed","dismissedQuestionsMessageId":"a1"}}]}
        """
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: json.data(using: .utf8)!)
        #expect(msg.questionsDismissedNotice?.dismissedQuestionsMessageId == "a1")
    }
}

// MARK: - ConversationMessage Tests

struct ConversationMessageTests {
    @Test func parseMessageFull() throws {
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
        #expect(msg?.contentBlocks?.count == 1)
        #expect(msg?.contentBlocks?.first?.resolvedText == "Hello")
        #expect(msg?.toolCalls?.count == 1)
        #expect(msg?.toolCalls?.first?.name == "read_file")
        #expect(msg?.toolResults?.count == 1)
        #expect(msg?.metadata?["key"]?.stringValue == "value")
    }

    @Test func parseMessageMinimal() throws {
        let dict: [String: Any] = [
            "id": "msg-2",
            "role": "user"
        ]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg != nil)
        #expect(msg?.id == "msg-2")
        #expect(msg?.role == .user)
        #expect(msg?.timestamp == "")
        #expect(msg?.contentBlocks == nil)
        #expect(msg?.toolCalls == nil)
        #expect(msg?.isStreaming == nil)
    }

    @Test func parseMessageMissingIdReturnsNil() throws {
        let dict: [String: Any] = ["role": "user"]
        let msg = ConversationMessage.parseMessage(dict)
        #expect(msg == nil)
    }

    @Test func parseMessageUnknownRoleDefaultsToSystem() throws {
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
            isStreaming: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(decoded.id == "msg-rt")
        #expect(decoded.role == .user)
        #expect(decoded.contentBlocks?.first?.resolvedText == "test")
        #expect(decoded.turnNumber == 1)
    }
}

// MARK: - QueuedMessage Tests

struct QueuedMessageTests {
    @Test func initAndCodable() throws {
        let msg = QueuedMessage(id: "q-1", content: "hello", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: data)
        #expect(decoded.id == "q-1")
        #expect(decoded.content == "hello")
        #expect(decoded.queuedAt == "2025-01-01T00:00:00Z")
        #expect(decoded.position == 0)
        #expect(decoded.imageBlocks == nil)
    }

    @Test func withImageBlocks() throws {
        let img = ImageBlock(type: "image", data: "abc123", mimeType: "image/jpeg")
        let msg = QueuedMessage(id: "q-2", content: "see image", queuedAt: "2025-01-01T00:00:00Z", position: 1, imageBlocks: [img])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: data)
        #expect(decoded.imageBlocks?.count == 1)
        #expect(decoded.imageBlocks?.first?.mimeType == "image/jpeg")
        #expect(decoded.imageBlocks?.first?.data == "abc123")
    }

    @Test func decodesWithoutMessageMetadata() throws {
        // Backward compat: wire entries without messageMetadata must decode.
        let json = """
        {"id": "q-1", "content": "hello", "queuedAt": "2025-01-01T00:00:00Z", "position": 0}
        """
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(decoded.messageMetadata == nil)
        #expect(decoded.isUserMessage)
    }

    @Test func decodesWithMessageMetadata() throws {
        let json = """
        {"id": "q-1", "content": "wake", "queuedAt": "2025-01-01T00:00:00Z", "position": 0, \
        "messageMetadata": {"type": "agent_message", "fromAgentId": "agent-2"}}
        """
        let decoded = try JSONDecoder().decode(QueuedMessage.self, from: Data(json.utf8))
        #expect(decoded.messageMetadata?["type"]?.stringValue == "agent_message")
        #expect(decoded.messageMetadata?["fromAgentId"]?.stringValue == "agent-2")
    }

    // MARK: isUserMessage predicate (shared with FE, see spec Background)

    private func queued(metadata: [String: AnyCodable]?) -> QueuedMessage {
        QueuedMessage(id: "q", content: "c", queuedAt: "2025-01-01T00:00:00Z",
                      position: 0, imageBlocks: nil, messageMetadata: metadata)
    }

    @Test func isUserMessageTrueWithoutMetadata() {
        #expect(queued(metadata: nil).isUserMessage)
    }

    @Test func isUserMessageTrueWithBenignMetadata() {
        #expect(queued(metadata: [
            "userAppMessageId": AnyCodable("uam-1"),
            "queueInfo": AnyCodable(["position": 1]),
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
            "answeredQuestionsMessageId": AnyCodable("qm-1"),
        ]).isUserMessage)
    }

    @Test func isUserMessageQuestionAnswersExemptionPrecedesOtherRules() {
        // Matches fe ordering: the question_answers exemption returns early,
        // before the fromAgentId and source hide rules.
        #expect(queued(metadata: [
            "type": AnyCodable("question_answers"),
            "fromAgentId": AnyCodable("agent-2"),
            "source": AnyCodable("system"),
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
            "fromAgentId": AnyCodable(true),
        ]).isUserMessage)
    }
}

// MARK: - ImageBlock Tests

struct ImageBlockTests {
    @Test func initAndCodable() throws {
        let block = ImageBlock(type: "image", data: "base64data", mimeType: "image/png")
        let data = try JSONEncoder().encode(block)
        let decoded = try JSONDecoder().decode(ImageBlock.self, from: data)
        #expect(decoded.type == "image")
        #expect(decoded.data == "base64data")
        #expect(decoded.mimeType == "image/png")
    }
}

// MARK: - SuggestedPrompts Tests

struct SuggestedPromptsTests {

    // MARK: - Valid formats

    @Test func parsesPlainPrompts() {
        let text = "Done!\n<!-- suggested-prompts\nRun the tests\nShip it\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests", "Ship it"])
    }

    @Test func stripsLabelAndDelayPrefixes() {
        // Mirrors the desktop's `Label|` / `delay:N|` stripping so both
        // clients surface identical chip text.
        let text = "<!-- suggested-prompts\nShort label|Full prompt text\ndelay:60|Check deployment\nLabel|delay:30|Check build\nDELAY:120|Check CI\n-->"
        #expect(SuggestedPrompts.parse(text) == [
            "Full prompt text",
            "Check deployment",
            "Check build",
            "Check CI",
        ])
    }

    @Test func dropsPromptEmptyAfterPrefixStripping() {
        // `delay:60|` with no remainder is an invalid line: dropped, the
        // valid siblings survive.
        let text = "<!-- suggested-prompts\ndelay:60|\nValid prompt\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Valid prompt"])
    }

    @Test func trimsWhitespaceAndSkipsBlankLines() {
        let text = "<!-- suggested-prompts\n  Spaced prompt  \n\n\nSecond\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Spaced prompt", "Second"])
    }

    @Test func toleratesWhitespaceAroundOpenerAndCloser() {
        let text = "<!--   suggested-prompts   \nA prompt\n   -->   "
        #expect(SuggestedPrompts.parse(text) == ["A prompt"])
    }

    @Test func trailingCloserWithRemainderClosesBlock() {
        // The raw closer-bearing line always matches the Mermaid-edge pattern,
        // so this also proves the body-text gate runs on the remainder.
        let text = """
        Done!
        <!-- suggested-prompts
        Run the tests
        Ship it
        Leave rewrite parked for now. -->
        """
        #expect(SuggestedPrompts.parse(text) == [
            "Run the tests",
            "Ship it",
            "Leave rewrite parked for now.",
        ])
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func trailingCloserBodyShapedRemainderStripsButYieldsNoPrompts() {
        let text = "Done!\n<!-- suggested-prompts\n## Heading -->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func openerShapedTrailingCloserDoesNotCloseBlock() {
        // `<!-- suggested-prompts -->` under an unclosed opener must stay
        // inert: closing there would let stripBlocks delete the body text
        // captured by the outer opener.
        let text = """
        <!-- suggested-prompts
        Response text that must survive
        <!-- suggested-prompts -->
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    // MARK: - Malformed blocks

    @Test func ignoresOpenerInsideFencedCodeRegion() {
        let text = """
        Here is the convention:

        ```markdown
        <!-- suggested-prompts
        Not a real prompt
        -->
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func ignoresOpenerInsideTildeFencedRegion() {
        let text = "~~~\n<!-- suggested-prompts\nNope\n-->\n~~~"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerFollowedByMermaidArrowYieldsNoPrompts() {
        let text = """
        <!-- suggested-prompts
        ```mermaid
        flowchart LR
          A --> B
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func embeddedArrowDoesNotCloseBlock() {
        let text = "<!-- suggested-prompts\nStep A --> Step B\n"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerYieldsNoPrompts() {
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\nRun tests").isEmpty)
    }

    @Test func openerNotAtLineEndIsNotABlock() {
        let text = "<!-- suggested-prompts Run tests -->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func unclosedOpenerDoesNotSwallowLaterBlock() {
        // A second opener means the first was never closed; the scan must
        // resume there instead of consuming the inner, well-formed block.
        let text = """
        <!-- suggested-prompts
        A truncated example that is never closed
        <!-- suggested-prompts
        Run the tests
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
        #expect(SuggestedPrompts.stripBlocks(from: text) == """
        <!-- suggested-prompts
        A truncated example that is never closed
        """)
    }

    @Test func toleratesCRLFLineEndings() {
        let text = "Done!\r\n<!-- suggested-prompts\r\nRun the tests\r\n-->\r\n"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
    }

    // MARK: - Fence bookkeeping

    @Test func mismatchedFenceCharDoesNotCloseFence() {
        let text = """
        ```markdown
        ~~~
        <!-- suggested-prompts
        Quoted example
        -->
        ```
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func infoStringedLineInsideFenceDoesNotCloseFence() {
        let text = """
        ~~~
        ```swift
        <!-- suggested-prompts
        Quoted example
        -->
        ~~~
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func deeplyIndentedFenceMarkerDoesNotOpenFence() {
        // Four spaces is an indented code block, not a fence, so it must not
        // flip fence state and hide the real block that follows.
        let text = "    ```\n<!-- suggested-prompts\nRun the tests\n-->"
        #expect(SuggestedPrompts.parse(text) == ["Run the tests"])
    }

    // MARK: - Body-text rejection

    @Test func rejectsBlockContainingHeading() {
        let text = "<!-- suggested-prompts\n## Summary\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsBlockContainingTableRow() {
        let text = "<!-- suggested-prompts\n| Col | Col |\nRun tests\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsBlockContainingFenceMarker() {
        let text = "<!-- suggested-prompts\nRun tests\n```swift\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func rejectsEmptyBlock() {
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\n-->").isEmpty)
    }

    // MARK: - Last block wins

    @Test func lastWellFormedBlockWins() {
        let text = """
        <!-- suggested-prompts
        First block
        -->
        More text
        <!-- suggested-prompts
        Second block
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Second block"])
    }

    @Test func gateRejectedLastBlockYieldsNoPromptsEvenWithEarlierValidBlock() {
        // The gate applies only to the last well-formed block; an earlier block
        // must not resurface stale prompts.
        let text = """
        <!-- suggested-prompts
        Earlier prompt
        -->
        <!-- suggested-prompts
        ## Heading
        -->
        """
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }

    @Test func lastWellFormedBlockWinsOverQuotedExample() {
        let text = """
        ```
        <!-- suggested-prompts
        Quoted example
        -->
        ```
        <!-- suggested-prompts
        Real prompt
        -->
        """
        #expect(SuggestedPrompts.parse(text) == ["Real prompt"])
    }

    // MARK: - Caps

    @Test func capsAtFourPrompts() {
        let lines = (1...10).map { "Prompt \($0)" }.joined(separator: "\n")
        let prompts = SuggestedPrompts.parse("<!-- suggested-prompts\n\(lines)\n-->")
        #expect(prompts.count == SuggestedPrompts.maxPrompts)
        #expect(prompts == ["Prompt 1", "Prompt 2", "Prompt 3", "Prompt 4"])
    }

    @Test func allInvalidLinesYieldNoPromptsButBlockStillStrips() {
        let long = String(repeating: "x", count: SuggestedPrompts.maxPromptLength + 1)
        let text = "Done!\n<!-- suggested-prompts\n\(long)\n-->"
        #expect(SuggestedPrompts.parse(text).isEmpty)
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func dropsOverlongPrompts() {
        let long = String(repeating: "x", count: SuggestedPrompts.maxPromptLength + 1)
        let prompts = SuggestedPrompts.parse("<!-- suggested-prompts\n\(long)\nShort\n-->")
        #expect(prompts == ["Short"])
    }

    @Test func keepsPromptAtExactLengthLimit() {
        let atLimit = String(repeating: "x", count: SuggestedPrompts.maxPromptLength)
        #expect(SuggestedPrompts.parse("<!-- suggested-prompts\n\(atLimit)\n-->") == [atLimit])
    }

    // MARK: - Stripping

    @Test func stripsWellFormedBlock() {
        let text = "Done!\n<!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
    }

    @Test func stripsAllWellFormedBlocks() {
        let text = "A\n<!-- suggested-prompts\nOne\n-->\nB\n<!-- suggested-prompts\nTwo\n-->\nC"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "A\nB\nC")
    }

    @Test func stripKeepsTextBeforeInlineOpener() {
        let text = "Trailing text <!-- suggested-prompts\nRun tests\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Trailing text ")
    }

    @Test func stripLeavesUnclosedOpenerAndBodyIntact() {
        let text = "<!-- suggested-prompts\nA --> B\nMore body"
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func stripLeavesFencedBlockIntact() {
        let text = "```\n<!-- suggested-prompts\nExample\n-->\n```"
        #expect(SuggestedPrompts.stripBlocks(from: text) == text)
    }

    @Test func stripsBodyTextShapedBlock() {
        // A standalone `-->` closer makes the block unambiguously comment
        // delimited, so removing it can never remove body text — even though
        // it contributes no prompts.
        let text = "Done!\n<!-- suggested-prompts\n## Heading\n-->"
        #expect(SuggestedPrompts.stripBlocks(from: text) == "Done!")
        #expect(SuggestedPrompts.parse(text).isEmpty)
    }
}
