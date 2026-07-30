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

    @Test func unknownKindReturnsNil() throws {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Interrupted", "meta": ["kind": "interruption"]]
        ])
        #expect(msg?.attentionNotice == nil)
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
