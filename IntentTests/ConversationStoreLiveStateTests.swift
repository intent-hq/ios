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

    @Test func idleSnapshotClearsStaleStreaming() async throws {
        let (store, _) = makeStore()

        // Turn in flight at first snapshot.
        store.handleStreamEvent("subscription.push", params: snapshotParams(
            messages: [
                [
                    "id": "msg-1", "role": "user",
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
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ],
            [
                "id": "msg-2", "role": "assistant",
                "contentBlocks": [["type": "text", "id": "msg-2:0", "text": "Done"]],
                "timestamp": "2026-06-27T01:00:01.000Z"
            ]
        ]))
        #expect(store.isStreaming == false)
    }

    @Test func terminalFrameTimestampAdopted() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        // First block delta carries no timestamp — a local one is synthesized.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-1",
                        block: ["type": "text", "id": "msg-1:0", "text": "Working"])
        ]))
        #expect(store.messages.count == 1)
        #expect(!store.messages[0].timestamp.isEmpty)

        // Terminal frame carries the server timestamp — it must be adopted.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-1",
                        block: ["type": "text", "id": "msg-1:0", "text": "Working done"],
                        streamingComplete: true,
                        timestamp: "2026-06-27T01:00:05.000Z")
        ]))
        #expect(store.messages[0].timestamp == "2026-06-27T01:00:05.000Z")
    }

    @Test func initialFetchDoesNotClobberLiveSnapshot() async throws {
        let (store, fake) = makeStore()
        fake.delayMap["agent.getConversation"] = 100_000_000
        fake.responseMap["agent.getConversation"] = [
            "messages": [
                [
                    "id": "msg-1", "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-06-27T01:00:00.000Z"
                ]
            ]
        ]

        // Start the initial fetch (messages is empty → pre-await initial load).
        let fetchTask = Task { await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1") }

        // While the fetch is in flight, the chat snapshot seeds the transcript
        // including an in-flight assistant message the server page lacks.
        try await Task.sleep(nanoseconds: 20_000_000)
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ],
            [
                "id": "msg-2", "role": "assistant",
                "contentBlocks": [["type": "text", "id": "msg-2:0", "text": "Working"]],
                "timestamp": "2026-06-27T01:00:01.000Z",
                "isStreaming": true
            ]
        ]))

        await fetchTask.value

        // The completed fetch must merge, not wholesale-replace the live snapshot.
        #expect(store.messages.count == 2)
        #expect(store.messages[0].id == "msg-1")
        #expect(store.messages[1].id == "msg-2")
        #expect(store.messages[1].isStreaming == true)
    }

    // MARK: - Firehose gating while chat channel is live

    @Test func firehoseChunkIgnoredWhenChatLive() async throws {
        let (store, _) = makeStore()

        // Snapshot applied → chatLive; deltas own the transcript from here on.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        // Firehose stream events for the same turn must NOT mutate the transcript —
        // a chunk-created block would carry a client-generated id that the terminal
        // delta's removedIds cannot remove (duplicate text block).
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:chunk", "data": ["content": "duplicate text"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.isStreaming == false)

        // The delta channel still applies normally afterwards.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Real content"])
        ]))
        #expect(store.messages.count == 2)
        #expect(store.messages[1].contentBlocks?.count == 1)
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "Real content")
    }

    @Test func firehoseChunkStillAppliesWhenChatNotLive() async throws {
        // No chat.subscribe snapshot applied → chatLive is false (legacy fallback).
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:chunk", "data": ["content": "fallback text"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.messages[0].role == .assistant)
        #expect(store.messages[0].isStreaming == true)
        #expect(store.isStreaming == true)
        let text = (store.messages[0].contentBlocks ?? [])
            .compactMap { $0.resolvedText }
            .joined()
        #expect(text == "fallback text")
    }
}
