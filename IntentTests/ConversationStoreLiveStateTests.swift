import Foundation
import Testing
@testable import Intent

/// Live-state tests for the chat.subscribe channel using real PROTOCOL §7.1 wire
/// shapes: object-shaped seq-0 snapshots (messages page + activity flags) and
/// block-granularity deltas ({ agentId, messageId, role, block } entities).
@MainActor
struct ConversationStoreLiveStateTests {

    private func makeStore() -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.setTestChatChannel(subscriptionId: "sub-chat-123")
        return (store, fake)
    }

    /// Object-shaped seq-0 snapshot params (PROTOCOL §7.1).
    private func snapshotParams(
        messages: [[String: Any]],
        meta: [String: Any] = [:]
    ) -> [String: Any] {
        var snapshot: [String: Any] = ["agentId": "agent-1", "messages": messages]
        for (k, v) in meta { snapshot[k] = v }
        return [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": snapshot
        ]
    }

    /// Block-level delta params (PROTOCOL §7.1).
    private func deltaParams(
        seq: Int,
        added: [[String: Any]] = [],
        updated: [[String: Any]] = [],
        removedIds: [String] = []
    ) -> [String: Any] {
        return [
            "subscriptionId": "sub-chat-123",
            "kind": "delta",
            "seq": seq,
            "delta": ["added": added, "updated": updated, "removedIds": removedIds]
        ]
    }

    /// A delta entity carrying the full current block.
    private func blockEntity(
        messageId: String,
        block: [String: Any],
        streamingComplete: Bool = false,
        messageSeq: Int? = nil,
        timestamp: String? = nil
    ) -> [String: Any] {
        var entity: [String: Any] = [
            "agentId": "agent-1",
            "messageId": messageId,
            "role": "assistant",
            "block": block
        ]
        if streamingComplete { entity["streamingComplete"] = true }
        if let messageSeq = messageSeq { entity["messageSeq"] = messageSeq }
        if let timestamp = timestamp { entity["timestamp"] = timestamp }
        return entity
    }

    // MARK: - Snapshot application

    @Test func appliesObjectShapedSnapshot() async throws {
        let (store, _) = makeStore()

        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ],
                [
                    "id": "msg-2", "role": "assistant",
                    "contentBlocks": [["type": "text", "id": "msg-2:0", "text": "Hi there"]],
                    "timestamp": "2026-06-27T01:00:01.000Z"
                ]
            ],
            meta: ["truncated": false, "totalMessages": 2]
        )
        store.handleStreamEvent("subscription.push", params: params)

        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.totalMessageCount == 2)
        #expect(store.isStreaming == false)
    }

    // MARK: - Mid-turn hydration

    @Test func midTurnSnapshotShowsPartialAndStreaming() async throws {
        let (store, _) = makeStore()

        // Snapshot taken mid-turn: synthetic in-flight assistant message with
        // isStreaming true plus the activity-flags overlay.
        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Run the tests"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ],
                [
                    "id": "msg-2", "role": "assistant",
                    "contentBlocks": [["type": "text", "id": "msg-2:0", "text": "Let me check"]],
                    "timestamp": "2026-06-27T01:00:01.000Z",
                    "isStreaming": true
                ]
            ],
            meta: ["isResponding": true, "turnInFlight": true, "totalMessages": 2]
        )
        store.handleStreamEvent("subscription.push", params: params)

        #expect(store.messages.count == 2)
        #expect(store.messages[1].isStreaming == true)
        #expect(store.isStreaming == true)
    }

    @Test func activityFlagsAloneRaiseStreaming() async throws {
        let (store, _) = makeStore()

        // Turn in flight but no partial content yet (no synthetic message).
        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ],
            meta: ["turnInFlight": true]
        )
        store.handleStreamEvent("subscription.push", params: params)

        #expect(store.isStreaming == true)
    }

    // MARK: - Growing-text delta sequence

    @Test func growingTextDeltasAccumulateFullText() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))

        // First chunk: block's first appearance → added, full text so far
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Let me"])
        ]))
        // Growth: updated carries the FULL accumulated text
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Let me check the logs."])
        ]))

        #expect(store.messages.count == 2)
        let assistant = store.messages[1]
        #expect(assistant.id == "msg-2")
        #expect(assistant.role == .assistant)
        #expect(assistant.isStreaming == true)
        #expect(assistant.contentBlocks?.count == 1)
        #expect(assistant.contentBlocks?.first?.resolvedText == "Let me check the logs.")
        #expect(store.isStreaming == true)
    }

    // MARK: - Tool blocks

    @Test func toolUseAndResultBlocksAppendInOrder() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Running tests."])
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:1", "name": "launch-process",
                "input": ["command": "npm test"], "toolCallId": "call-1"
            ])
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 3, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_result", "id": "msg-2:2", "tool_use_id": "call-1",
                "output": "ok", "is_error": false
            ])
        ]))

        let blocks = store.messages[0].contentBlocks ?? []
        #expect(blocks.count == 3)
        #expect(blocks[0].type == .text)
        #expect(blocks[1].type == .toolUse)
        #expect(blocks[2].type == .toolResult)
        #expect(blocks[2].resolvedToolUseId == "call-1")
    }

    // MARK: - Terminal frame

    @Test func terminalFrameClearsStreamingAndHonorsRemovedIds() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        // Live chunks: one real block, one orphan the persisted message drops
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Partial"]),
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:1", "text": "orphan"])
        ]))
        #expect(store.isStreaming == true)

        // Terminal reconcile: persisted block as updated with streamingComplete,
        // orphan removed
        store.handleStreamEvent("subscription.push", params: deltaParams(
            seq: 2,
            updated: [
                blockEntity(messageId: "msg-2",
                            block: ["type": "text", "id": "msg-2:0", "text": "Partial + final."],
                            streamingComplete: true,
                            messageSeq: 1,
                            timestamp: "2026-06-27T01:00:05.000Z")
            ],
            removedIds: ["msg-2:1"]
        ))

        let assistant = store.messages[0]
        #expect(assistant.isStreaming == false)
        let blocks = assistant.contentBlocks ?? []
        #expect(blocks.count == 1)
        #expect(blocks[0].resolvedText == "Partial + final.")
        #expect(store.isStreaming == false)
    }

    // MARK: - Gap detection

    @Test func gapLeavesTranscriptUntouched() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))

        // Gap: expected seq 1, got 5 — delta must not apply
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 5, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "lost"])
        ]))

        #expect(store.messages.count == 1)
    }

    // MARK: - Malformed push rejection

    @Test func rejectsMalformedPush() async throws {
        // Snapshot push missing "snapshot" field
        let malformedParams: [String: Any] = [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0
            // Missing "snapshot" field
        ]

        let push = SubscriptionPush.parse(method: "subscription.push", params: malformedParams)
        #expect(push == nil) // Should return nil for malformed push
    }

    // MARK: - fetchConversation merge preserves in-flight message

    @Test func fetchMergePreservesInFlightStreamingMessage() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.getConversation"] = [
            "messages": [
                [
                    "id": "msg-1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ]
        ]

        // Seed the transcript, then stream an in-flight assistant message the
        // server page does not yet contain (mid-turn content is not persisted).
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Working on it"])
        ]))
        #expect(store.messages.count == 2)

        // Non-initial merge fetch must not wipe the in-flight message
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.messages[1].isStreaming == true)
    }
}
