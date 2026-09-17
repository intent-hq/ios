import Foundation
@testable import Intent
import Testing

/// ios#258 measurement harness for transcript decoding. Every chat snapshot
/// page and every block delta arrives as `[[String: Any]]` from the inbound
/// frame parser and is re-serialized to `Data` and run through a
/// `JSONDecoder` to reach the `Codable` models. Per-row decoding paid one
/// `JSONSerialization.isValidJSONObject` walk, one `JSONSerialization.data`
/// and one fresh `JSONDecoder` per message (and per delta block); the batched
/// decoders pay each once per page/delta.
///
/// The harness decodes representative payloads both ways, asserts the outputs
/// are identical, and prints median wall time per payload with an `[ios#258]`
/// prefix for the issue/PR table. Timing is informational — CI simulators are
/// noisy — so the only asserted contract is output parity.
@Suite(.serialized)
struct TranscriptDecodingMeasurementTests {
    private static let iterations = 15
    private static let toolOutputLineCount = 60
    private static let toolOutputLine = "src/Feature/File.swift:42: note: something the tool reported\n"
    private static let deltaMessageCount = 10
    private static let deltaTerminalStride = 4
    private static let secondsPerMinute = 60

    private struct Measurement {
        let label: String
        let items: Int
        let perItemMedian: Duration
        let batchedMedian: Duration

        var markdownRow: String {
            let ratio = Double(perItemMedian.microseconds) / Double(max(batchedMedian.microseconds, 1))
            return "| \(label) | \(items) | \(perItemMedian.milliString) | \(batchedMedian.milliString) "
                + "| \(String(format: "%.2fx", ratio)) |"
        }
    }

    // MARK: - Payloads

    /// One assistant turn shaped like production: thinking, a tool call
    /// whose result carries a multi-line output, then a text answer.
    private static func assistantRow(turn: Int) -> [String: Any] {
        let output = String(repeating: toolOutputLine, count: toolOutputLineCount)
        return [
            "id": "msg-\(turn)-a",
            "role": "assistant",
            "timestamp": "2026-09-17T02:00:\(String(format: "%02d", turn % secondsPerMinute))Z",
            "turnNumber": turn,
            "isStreaming": false,
            "contentBlocks": [
                ["type": "thinking", "text": "Considering the request for turn \(turn) before acting on it."],
                ["type": "tool_use", "name": "read_file", "toolUseId": "tc-\(turn)", "input": ["path": "src/File\(turn).swift"]],
                ["type": "tool_result", "toolUseId": "tc-\(turn)", "output": output, "outputTruncated": false, "outputBytes": output.utf8.count],
                ["type": "text", "text": "Turn \(turn): the file looks fine, moving on to the next step."]
            ],
            "toolCalls": [["id": "tc-\(turn)", "name": "read_file", "status": "completed"]],
            "toolResults": [["toolCallId": "tc-\(turn)", "isError": false, "content": output]],
            "metadata": ["model": "demo", "turn": turn]
        ]
    }

    private static func userRow(turn: Int) -> [String: Any] {
        [
            "id": "msg-\(turn)-u",
            "role": "user",
            "timestamp": "2026-09-17T01:59:\(String(format: "%02d", turn % secondsPerMinute))Z",
            "contentBlocks": [["type": "text", "text": "Please look at file \(turn) and report back."]]
        ]
    }

    /// `turns` user/assistant pairs, i.e. `2 * turns` message rows.
    static func snapshotPage(turns: Int) -> [[String: Any]] {
        (0..<turns).flatMap { [userRow(turn: $0), assistantRow(turn: $0)] }
    }

    /// A streaming delta: `count` block entities spread over ten messages.
    static func blockDelta(count: Int) -> [[String: Any]] {
        (0..<count).map { index in
            let messageId = "msg-\(index % deltaMessageCount)-a"
            let textBlock: [String: Any] = ["type": "text", "text": "streamed chunk \(index) of the answer"]
            let toolBlock: [String: Any] = [
                "id": "\(messageId):\(index)", "type": "tool_use", "name": "grep", "input": ["q": "\(index)"]
            ]
            return [
                "messageId": messageId,
                "role": "assistant",
                "streamingComplete": (index + 1).isMultiple(of: deltaTerminalStride),
                "block": index.isMultiple(of: 2) ? textBlock : toolBlock
            ]
        }
    }

    // MARK: - Timing

    private static func median(of samples: [Duration]) -> Duration {
        samples.sorted()[samples.count / 2]
    }

    private static func time(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        var samples: [Duration] = []
        body() // warm-up
        for _ in 0..<iterations {
            samples.append(clock.measure(body))
        }
        return median(of: samples)
    }

    private static func measure(label: String, items: Int, perItem: () -> Void, batched: () -> Void) {
        let measurement = Measurement(
            label: label, items: items, perItemMedian: time(perItem), batchedMedian: time(batched)
        )
        print("[ios#258] \(measurement.markdownRow)")
    }

    // MARK: - Tests

    @Test(arguments: [10, 100, 500])
    func snapshotPageDecodesIdenticallyPerRowAndBatched(turns: Int) {
        let rows = Self.snapshotPage(turns: turns)
        let perRow = rows.compactMap { ConversationMessage.parseMessage($0) }
        let batched = ConversationMessage.parseMessages(rows)
        #expect(batched == perRow)
        #expect(batched.count == rows.count)
        #expect(batched.allSatisfy { $0.hasReportedContentBlocks })
        Self.measure(
            label: "chat snapshot page",
            items: rows.count,
            perItem: { _ = rows.compactMap { ConversationMessage.parseMessage($0) } },
            batched: { _ = ConversationMessage.parseMessages(rows) }
        )
    }

    @Test(arguments: [8, 64, 256])
    func blockDeltaDecodesIdenticallyPerEntityAndBatched(count: Int) throws {
        let entities = Self.blockDelta(count: count)
        let perEntity = entities.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) }
        let batched = try #require(SubscriptionPush.DeltaPayload.decodeChatBlocks(added: entities, updated: []))
        #expect(batched.count == perEntity.count)
        #expect(batched.map(\.block) == perEntity.map(\.block))
        #expect(batched.map(\.messageId) == perEntity.map(\.messageId))
        #expect(batched.map(\.streamingComplete) == perEntity.map(\.streamingComplete))
        Self.measure(
            label: "block delta",
            items: entities.count,
            perItem: { _ = entities.compactMap { SubscriptionPush.ChatBlockEntity(entity: $0) } },
            batched: { _ = SubscriptionPush.DeltaPayload.decodeChatBlocks(added: entities, updated: []) }
        )
    }
}

private extension Duration {
    private static let microsecondsPerSecond: Int64 = 1_000_000
    private static let attosecondsPerMicrosecond: Int64 = 1_000_000_000_000
    private static let microsecondsPerMillisecond = 1000.0

    var microseconds: Int64 {
        components.seconds * Self.microsecondsPerSecond + components.attoseconds / Self.attosecondsPerMicrosecond
    }

    var milliString: String {
        String(format: "%.3f ms", Double(microseconds) / Self.microsecondsPerMillisecond)
    }
}
