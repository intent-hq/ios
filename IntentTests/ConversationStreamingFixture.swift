import Foundation

/// Matched protocol traces for the same content. No reducer lives in the
/// fixture: tests feed these frames through SubscriptionPush and the store.
/// Text and thinking use UTF-8 beyond ASCII to catch character/byte confusion.
struct ConversationStreamingFixture {
    enum Encoding {
        case full
        case incremental
    }

    static let subscriptionId = "fixture-chat"
    static let agentId = "fixture-agent"
    static let messageId = "fixture-message"
    static let timestamp = "2026-09-27T00:00:00.000Z"
    static let fullToolOutputBytes = 900_000
    var fragments = [" café", " 🦊", " ready"]
    var startsWithPartial = true

    var textPrefix: String { startsWithPartial ? "Hello" : "" }
    var thinkingPrefix: String { startsWithPartial ? "Plan" : "" }
    var finalText: String { textPrefix + fragments.joined() }
    var finalThinking: String { thinkingPrefix + fragments.joined() }

    var toolBlocks: [[String: Any]] {
        [
            ["id": "tool-use", "type": "tool_use", "name": "read_file", "toolCallId": "call-1", "input": ["path": "café.txt"]],
            [
                "id": "tool-result", "type": "tool_result", "toolUseId": "call-1",
                "output": "preview…", "outputTruncated": true, "outputBytes": Self.fullToolOutputBytes
            ]
        ]
    }

    var authoritativeMessage: [String: Any] {
        message(blocks: textBlocks(text: finalText, thinking: finalThinking) + toolBlocks)
    }

    func snapshot(encoding: Encoding, echoEncoding: Bool = true) -> [String: Any] {
        let blocks = startsWithPartial ? textBlocks(text: textPrefix, thinking: thinkingPrefix) : []
        var row = message(blocks: blocks)
        row["isStreaming"] = true
        var snapshot: [String: Any] = [
            "agentId": Self.agentId, "messages": [row], "totalMessages": 1,
            "truncated": false, "nextToken": NSNull(), "isResponding": true, "turnInFlight": true
        ]
        if encoding == .incremental, echoEncoding { snapshot["deltaEncoding"] = "incremental" }
        return ["subscriptionId": Self.subscriptionId, "kind": "snapshot", "seq": 0, "snapshot": snapshot]
    }

    func growth(encoding: Encoding) -> [[String: Any]] {
        fragments.indices.map { index in
            let field = encoding == .incremental ? "textDelta" : "text"
            let text = encoding == .incremental ? fragments[index] : textPrefix + fragments[...index].joined()
            let thinking = encoding == .incremental ? fragments[index] : thinkingPrefix + fragments[...index].joined()
            let entities = [
                entity(block: ["id": "text-1", "type": "text", field: text]),
                entity(block: ["id": "thinking-1", "type": "thinking", field: thinking])
            ]
            let isFirstInsertion = !startsWithPartial && index == 0
            return delta(seq: index + 1, added: isFirstInsertion ? entities : [], updated: isFirstInsertion ? [] : entities)
        }
    }

    var toolFrame: [String: Any] {
        delta(seq: fragments.count + 1, added: toolBlocks.map { entity(block: $0) })
    }

    var terminal: [String: Any] {
        delta(
            seq: fragments.count + 2,
            updated: (textBlocks(text: finalText, thinking: finalThinking) + toolBlocks).map { block in
                entity(block: block, streamingComplete: true)
            }
        )
    }

    func frames(encoding: Encoding) -> [[String: Any]] {
        [snapshot(encoding: encoding)] + growth(encoding: encoding) + [toolFrame, terminal]
    }

    func delta(seq: Int, added: [[String: Any]] = [], updated: [[String: Any]] = []) -> [String: Any] {
        [
            "subscriptionId": Self.subscriptionId, "kind": "delta", "seq": seq,
            "delta": ["added": added, "updated": updated, "removedIds": [String]()]
        ]
    }

    func entity(block: [String: Any], streamingComplete: Bool = false) -> [String: Any] {
        [
            "agentId": Self.agentId, "messageId": Self.messageId, "role": "assistant",
            "timestamp": Self.timestamp, "streamingComplete": streamingComplete, "block": block
        ]
    }

    private func message(blocks: [[String: Any]]) -> [String: Any] {
        [
            "id": Self.messageId, "agentId": Self.agentId, "role": "assistant",
            "timestamp": Self.timestamp, "contentBlocks": blocks
        ]
    }

    private func textBlocks(text: String, thinking: String) -> [[String: Any]] {
        [["id": "text-1", "type": "text", "text": text], ["id": "thinking-1", "type": "thinking", "text": thinking]]
    }
}
