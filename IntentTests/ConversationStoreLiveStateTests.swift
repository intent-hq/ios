import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

/// Live-state tests for the chat.subscribe channel using real PROTOCOL §7.1 wire
/// shapes: object-shaped seq-0 snapshots (messages page + activity flags) and
/// block-granularity deltas ({ agentId, messageId, role, block } entities).
@MainActor
struct ConversationStoreLiveStateTests {
    func makeStore() -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.setTestChatChannel(subscriptionId: "sub-chat-123")
        return (store, fake)
    }

    /// Object-shaped seq-0 snapshot params (PROTOCOL §7.1).
    func snapshotParams(
        messages: [[String: Any]],
        meta: [String: Any] = [:]
    ) -> [String: Any] {
        var snapshot: [String: Any] = ["agentId": "agent-1", "messages": messages]
        for (key, value) in meta { snapshot[key] = value }
        return [
            "subscriptionId": "sub-chat-123",
            "kind": "snapshot",
            "seq": 0,
            "snapshot": snapshot
        ]
    }

    /// Block-level delta params (PROTOCOL §7.1).
    func deltaParams(
        seq: Int,
        added: [[String: Any]] = [],
        updated: [[String: Any]] = [],
        removedIds: [String] = []
    ) -> [String: Any] {
        [
            "subscriptionId": "sub-chat-123",
            "kind": "delta",
            "seq": seq,
            "delta": ["added": added, "updated": updated, "removedIds": removedIds]
        ]
    }

    /// A delta entity carrying the full current block.
    func blockEntity(
        messageId: String,
        block: [String: Any],
        role: String = "assistant",
        streamingComplete: Bool = false,
        messageSeq: Int? = nil,
        timestamp: String? = nil
    ) -> [String: Any] {
        var entity: [String: Any] = [
            "agentId": "agent-1",
            "messageId": messageId,
            "role": role,
            "block": block
        ]
        if streamingComplete { entity["streamingComplete"] = true }
        if let messageSeq { entity["messageSeq"] = messageSeq }
        if let timestamp { entity["timestamp"] = timestamp }
        return entity
    }

    // MARK: - Snapshot application

    @Test func appliesObjectShapedSnapshot() async {
        let (store, _) = makeStore()

        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ],
                [
                    "id": "msg-2",
                    "role": "assistant",
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

    @Test func forwardedTranscriptStateRemainsObservable() {
        let (store, _) = makeStore()
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = store.messages.count
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        store.handleStreamEvent(
            "subscription.push",
            params: snapshotParams(messages: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ])
        )

        #expect(changeCount.withLock { $0 } == 1)
    }

    @Test func snapshotWithoutMetaResetsTruncationDefaults() async {
        let (store, _) = makeStore()

        // First snapshot marks the transcript truncated.
        store.handleStreamEvent("subscription.push", params: snapshotParams(
            messages: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ],
            meta: ["truncated": true, "totalMessages": 50]
        ))
        #expect(store.isTruncated == true)
        #expect(store.totalMessageCount == 50)

        // A later snapshot omitting the meta keys is still authoritative:
        // stale truncation state must reset to defaults.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.isTruncated == false)
        #expect(store.totalMessageCount == 1)
    }

    // MARK: - Mid-turn hydration

    @Test func midTurnSnapshotShowsPartialAndStreaming() async {
        let (store, _) = makeStore()

        // Snapshot taken mid-turn: synthetic in-flight assistant message with
        // isStreaming true plus the activity-flags overlay.
        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Run the tests"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ],
                [
                    "id": "msg-2",
                    "role": "assistant",
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

    @Test func activityFlagsAloneRaiseStreaming() async {
        let (store, _) = makeStore()

        // Turn in flight but no partial content yet (no synthetic message).
        let params = snapshotParams(
            messages: [
                [
                    "id": "msg-1",
                    "role": "user",
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

    @Test func growingTextDeltasAccumulateFullText() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))

        // First chunk: block's first appearance → added, full text so far
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Let me"]
            )
        ]))
        // Growth: updated carries the FULL accumulated text
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Let me check the logs."]
            )
        ]))

        #expect(store.messages.count == 2)
        let assistant = store.messages[1]
        #expect(assistant.id == "msg-2")
        #expect(assistant.role == .assistant)
        #expect(assistant.isStreaming == true)
        #expect(assistant.contentBlocks.count == 1)
        #expect(assistant.contentBlocks.first?.resolvedText == "Let me check the logs.")
        #expect(store.isStreaming == true)
    }

    // MARK: - Tool blocks
}

extension ConversationStoreLiveStateTests {
    @Test func toolUseAndResultBlocksAppendInOrder() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Running tests."]
            )
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:1",
                "name": "launch-process",
                "input": ["command": "npm test"],
                "toolCallId": "call-1"
            ])
        ]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 3, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_result",
                "id": "msg-2:2",
                "tool_use_id": "call-1",
                "output": "ok",
                "is_error": false
            ])
        ]))

        let blocks = store.messages[0].contentBlocks
        #expect(blocks.count == 3)
        #expect(blocks[0].type == .text)
        #expect(blocks[1].type == .toolUse)
        #expect(blocks[2].type == .toolResult)
        #expect(blocks[2].resolvedToolUseId == "call-1")
    }

    // MARK: - Terminal frame

    @Test func terminalFrameClearsStreamingAndHonorsRemovedIds() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        // Live chunks: one real block, one orphan the persisted message drops
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "Partial"]
            ),
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:1", "text": "orphan"]
            )
        ]))
        #expect(store.isStreaming == true)

        // Terminal reconcile: persisted block as updated with streamingComplete,
        // orphan removed
        store.handleStreamEvent("subscription.push", params: deltaParams(
            seq: 2,
            updated: [
                blockEntity(
                    messageId: "msg-2",
                    block: ["type": "text", "id": "msg-2:0", "text": "Partial + final."],
                    streamingComplete: true,
                    messageSeq: 1,
                    timestamp: "2026-06-27T01:00:05.000Z"
                )
            ],
            removedIds: ["msg-2:1"]
        ))

        let assistant = store.messages[0]
        #expect(assistant.isStreaming == false)
        let blocks = assistant.contentBlocks
        #expect(blocks.count == 1)
        #expect(blocks[0].resolvedText == "Partial + final.")
        #expect(store.isStreaming == false)
    }

    // MARK: - Gap detection

    @Test func gapLeavesTranscriptUntouched() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))

        // Gap: expected seq 1, got 5 — delta must not apply
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 5, added: [
            blockEntity(
                messageId: "msg-2",
                block: ["type": "text", "id": "msg-2:0", "text": "lost"]
            )
        ]))

        #expect(store.messages.count == 1)
    }

    // MARK: - Malformed push rejection

    @Test func rejectsMalformedPush() async {
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

    @Test func idleSnapshotClearsStaleStreaming() async {
        let (store, _) = makeStore()

        // Turn in flight at first snapshot.
        store.handleStreamEvent("subscription.push", params: snapshotParams(
            messages: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ],
            meta: ["turnInFlight": true]
        ))
        #expect(store.isStreaming == true)

        // Resnapshot after the turn ended: no in-flight message, no activity flags.
        // The snapshot is authoritative — stale streaming state must clear.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ],
            [
                "id": "msg-2",
                "role": "assistant",
                "contentBlocks": [["type": "text", "id": "msg-2:0", "text": "Done"]],
                "timestamp": "2026-06-27T01:00:01.000Z"
            ]
        ]))
        #expect(store.isStreaming == false)
    }
}
