import Foundation
@testable import Intent
import Testing

struct ContentBlockTests {
    @Test func decodeTextBlock() throws {
        let json = #"{"type":"text","text":"Hello world"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .text)
        #expect(block.resolvedText == "Hello world")
        #expect(!block.id.isEmpty) // deterministic fallback identity (ios#257)
    }

    @Test func decodeToolUseBlock() throws {
        let json = #"{"type":"tool_use","name":"read_file","input":{"path":"foo.txt"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .toolUse)
        #expect(block.resolvedName == "read_file")
        #expect(block.hasReportedInput)
    }

    @Test func decodeToolResultBlock() throws {
        let json = #"{"type":"tool_result","toolUseId":"tc-1","output":"ok","isError":false}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .toolResult)
        #expect(block.resolvedToolUseId == "tc-1")
        #expect(block.resolvedErrorOutcome == .succeeded)
    }

    @Test func decodeThinkingBlock() throws {
        let json = #"{"type":"thinking","text":"Let me think..."}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .thinking)
        #expect(block.resolvedText == "Let me think...")
    }

    @Test func decodeImageBlock() throws {
        let json = #"{"type":"image","data":"base64data","mimeType":"image/png"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .image)
        #expect(block.data == "base64data")
        #expect(block.mimeType == "image/png")
    }

    @Test func decodeAttachmentReferenceImageBlock() throws {
        // Persisted attachment-reference image block (PROTOCOL §5.5 v7.4):
        // carries attachmentId + mimeType, no inline data.
        let json = #"{"type":"image","attachmentId":"att-42","mimeType":"image/jpeg"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.type == .image)
        #expect(block.attachmentId == "att-42")
        #expect(block.mimeType == "image/jpeg")
        #expect(block.data == nil)
        #expect(!block.isSlimTruncated)
    }

    // MARK: Slim projection flags (PROTOCOL §5.5)

    @Test func decodeSlimTruncatedToolUseBlock() throws {
        let json = #"{"type":"tool_use","name":"write_file","input":{"path":"foo.txt"},"inputTruncated":true,"inputBytes":900000}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.inputTruncation == .truncated)
        #expect(block.inputBytes == 900_000)
        #expect(block.isSlimTruncated)
    }

    @Test func decodeSlimTruncatedToolResultBlock() throws {
        let json = #"{"type":"tool_result","toolUseId":"tc-1","output":"preview…","outputTruncated":true,"outputBytes":1200000}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.outputTruncation == .truncated)
        #expect(block.outputBytes == 1_200_000)
        #expect(block.isSlimTruncated)
    }

    @Test func decodeSlimThumbnailImageBlock() throws {
        let json = #"{"type":"image","data":"thumbB64","mimeType":"image/webp","dataTruncated":true,"dataIsThumbnail":true,"dataBytes":4000000}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.dataTruncation == .truncated)
        #expect(block.dataRepresentation == .thumbnail)
        #expect(block.dataBytes == 4_000_000)
        #expect(block.data == "thumbB64")
        #expect(block.isSlimTruncated)
    }

    @Test func decodeSlimTruncatedImageWithoutThumbnail() throws {
        // Legacy rows / failed thumbnail generation: data omitted entirely.
        let json = #"{"type":"image","mimeType":"image/png","dataTruncated":true,"dataBytes":4000000}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.data == nil)
        #expect(block.dataTruncation == .truncated)
        #expect(block.dataRepresentation == .unreported)
        #expect(block.isSlimTruncated)
    }

    @Test func untruncatedBlockIsNotSlimTruncated() throws {
        let json = #"{"type":"tool_use","name":"read_file","input":{"path":"foo.txt"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.inputTruncation == .unreported)
        #expect(!block.isSlimTruncated)
    }

    @Test func legacyContentFallback() throws {
        let json = #"{"type":"text","content":"legacy text"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.text == nil)
        #expect(block.resolvedText == "legacy text")
    }

    @Test func legacyToolNameFallback() throws {
        let json = #"{"type":"tool_use","toolName":"old_tool"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.name == nil)
        #expect(block.resolvedName == "old_tool")
    }

    @Test func legacyToolUseIdFallback() throws {
        let json = #"{"type":"tool_result","tool_use_id":"tc-legacy"}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.toolUseId == nil)
        #expect(block.resolvedToolUseId == "tc-legacy")
    }

    @Test func legacyIsErrorFallback() throws {
        let json = #"{"type":"tool_result","is_error":true}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.errorOutcome == .unreported)
        #expect(block.resolvedErrorOutcome == .failed)
    }

    @Test func decodeMetaAlias() throws {
        let json = #"{"type":"text","text":"reason","meta":{"kind":"discussion-request"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.metadata.isEmpty)
        #expect(!block.hasReportedMetadata)
        #expect(block.resolvedMetadata["kind"]?.stringValue == "discussion-request")
    }

    @Test func resolvedMetadataPrefersMetadata() throws {
        let json = #"{"type":"text","text":"x","metadata":{"kind":"a"},"meta":{"kind":"b"}}"#
        let block = try JSONDecoder().decode(ContentBlock.self, from: Data(json.utf8))
        #expect(block.resolvedMetadata["kind"]?.stringValue == "a")
    }
}

// MARK: - AttentionNotice Tests

struct AttentionNoticeTests {
    private func systemMessage(blocks: [[String: Any]], role: String = "system") -> ConversationMessage? {
        ConversationMessage.parseMessage([
            "id": "msg-att",
            "role": role,
            "contentBlocks": blocks
        ])
    }

    @Test func classifiesDiscussionRequest() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Need input on the API shape", "meta": ["kind": "discussion-request"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .discussionRequest)
        #expect(notice?.reason == "Need input on the API shape")
    }

    @Test func classifiesBlockerReport() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Sandbox is broken", "meta": ["kind": "blocker-report"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .blockerReport)
        #expect(notice?.reason == "Sandbox is broken")
    }

    @Test func classifiesTurnFailure() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Model refused the request", "meta": ["kind": "turn-failure"]]
        ])
        let notice = msg?.attentionNotice
        #expect(notice?.kind == .turnFailure)
        #expect(notice?.reason == "Model refused the request")
    }

    @Test func unknownKindFallsBackToJoinedText() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": " Interrupted by restart ", "meta": ["kind": "interruption"]]
        ])
        #expect(msg?.attentionNotice == nil)
        #expect(msg?.joinedTextContent == "Interrupted by restart")
    }

    @Test func joinedTextContentEmptyForNoTextBlocks() {
        let msg = systemMessage(blocks: [["type": "tool_use", "name": "some_tool"]])
        #expect(msg?.joinedTextContent.isEmpty == true)
    }

    @Test func missingMetaReturnsNil() {
        let msg = systemMessage(blocks: [["type": "text", "text": "plain system message"]])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func nonSystemRoleReturnsNil() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "Need input", "meta": ["kind": "discussion-request"]]
        ], role: "assistant")
        #expect(msg?.attentionNotice == nil)
    }

    @Test func emptyContentBlocksReturnsNil() {
        let msg = systemMessage(blocks: [])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func nonStringKindReturnsNil() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "x", "meta": ["kind": 42]]
        ])
        #expect(msg?.attentionNotice == nil)
    }

    @Test func reasonJoinsTextBlocksAndTrims() {
        let msg = systemMessage(blocks: [
            ["type": "text", "text": "  first line ", "meta": ["kind": "blocker-report"]],
            ["type": "tool_use", "name": "some_tool"],
            ["type": "text", "text": "second line"]
        ])
        #expect(msg?.attentionNotice?.reason == "first line \nsecond line")
    }

    @Test func classifiesAfterCodableRoundTrip() throws {
        let json = """
        {"id":"msg-rt","role":"system","timestamp":"2026-07-30T00:00:00Z",
         "contentBlocks":[{"type":"text","text":"Reason","meta":{"kind":"discussion-request"}}]}
        """
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(msg.attentionNotice == AttentionNotice(kind: .discussionRequest, reason: "Reason"))
    }
}

// MARK: - ModelChangeNotice Tests (FE `model-change-notice.ts` parity)

struct ModelChangeNoticeTests {
    private let noticeText = "Model changed from claude-4 to gpt-5."

    private func message(role: String = "system") -> ConversationMessage? {
        ConversationMessage.parseMessage(messageDictionary(role: role))
    }

    private func message(metadata: [String: Any], role: String = "system") -> ConversationMessage? {
        var dict = messageDictionary(role: role)
        dict["metadata"] = metadata
        return ConversationMessage.parseMessage(dict)
    }

    private func messageDictionary(role: String) -> [String: Any] {
        [
            "id": "msg-mc",
            "role": role,
            "contentBlocks": [["type": "text", "text": noticeText]]
        ]
    }

    @Test func classifiesModelChangedRow() throws {
        let msg = message(metadata: [
            "type": "model_changed",
            "from": "claude-4",
            "to": "gpt-5",
            "fromProvider": "claude-code",
            "toProvider": "codex"
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(
            from: "claude-4",
            to: "gpt-5",
            fromProvider: "claude-code",
            toProvider: "codex"
        ))
    }

    @Test func nullModelIdsMapToNil() throws {
        // `from`/`to` are null for "provider default model" (PROTOCOL §5.5).
        let msg = message(metadata: [
            "type": "model_changed",
            "from": NSNull(),
            "to": "gpt-5",
            "fromProvider": "claude-code",
            "toProvider": "codex"
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice.from == nil)
        #expect(notice.destination == "gpt-5")
    }

    @Test func missingMetadataReturnsNil() {
        #expect(message()?.modelChangeNotice == nil)
    }

    @Test func otherMetadataTypeReturnsNil() {
        #expect(message(metadata: ["type": "questions_dismissed"])?.modelChangeNotice == nil)
    }

    @Test func nonStringTypeReturnsNil() {
        #expect(message(metadata: ["type": 42])?.modelChangeNotice == nil)
    }

    @Test func nonStringFieldsAreDroppedNotCrashing() throws {
        let msg = message(metadata: [
            "type": "model_changed",
            "from": 7,
            "to": ["x": 1],
            "fromProvider": true
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(from: nil, to: nil, fromProvider: nil, toProvider: nil))
    }

    @Test func emptyStringFieldsMapToNil() throws {
        // FE parity: asString requires value.length > 0.
        let msg = message(metadata: [
            "type": "model_changed",
            "from": "",
            "to": "gpt-5",
            "fromProvider": "",
            "toProvider": "codex"
        ])
        let notice = try #require(msg?.modelChangeNotice)
        #expect(notice == ModelChangeNotice(
            from: nil,
            to: "gpt-5",
            fromProvider: nil,
            toProvider: "codex"
        ))
    }

    @Test func classifiesRegardlessOfRole() {
        // FE parity: discriminates purely on metadata.type, tolerant of the
        // exact non-user/non-assistant role the daemon persists.
        let msg = message(metadata: ["type": "model_changed"], role: "model_change")
        #expect(msg?.modelChangeNotice != nil)
        #expect(msg?.role == .system)
    }

    @Test func labelDescribesBothSides() {
        let notice = ModelChangeNotice(
            from: "claude-4",
            to: "gpt-5",
            fromProvider: "claude-code",
            toProvider: "codex"
        )
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from claude-4 (Claude Code) to gpt-5 (Codex)")
    }

    @Test func labelDescribesProviderDefaultModel() {
        let notice = ModelChangeNotice(
            from: nil,
            to: "gpt-5",
            fromProvider: "claude-code",
            toProvider: "codex"
        )
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from Claude Code default model to gpt-5 (Codex)")
    }

    @Test func labelWithoutProviderUsesBareModelId() {
        let notice = ModelChangeNotice(
            from: "claude-4",
            to: "gpt-5",
            fromProvider: nil,
            toProvider: nil
        )
        #expect(notice.label(fallbackText: noticeText)
            == "Switched from claude-4 to gpt-5")
    }

    @Test func labelFallsBackToRowTextWhenSideUndescribable() {
        let notice = ModelChangeNotice(
            from: nil,
            to: "gpt-5",
            fromProvider: nil,
            toProvider: "codex"
        )
        #expect(notice.label(fallbackText: noticeText) == noticeText)
    }

    @Test func labelFallsBackToGenericWhenRowTextEmpty() {
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
        let msg = try JSONDecoder().decode(ConversationMessage.self, from: Data(json.utf8))
        #expect(msg.modelChangeNotice == ModelChangeNotice(
            from: "a",
            to: "b",
            fromProvider: "codex",
            toProvider: "codex"
        ))
    }

    @Test func malformedMetadataKeepsAttentionAndBannerPaths() {
        // A system row without model_changed metadata still classifies down
        // the existing chain: attention notices stay attention notices, and
        // unclassified rows keep the banner fallback via joinedTextContent.
        let attention = ConversationMessage.parseMessage([
            "id": "msg-a",
            "role": "system",
            "contentBlocks": [
                ["type": "text", "text": "Need input", "meta": ["kind": "discussion-request"]]
            ]
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
