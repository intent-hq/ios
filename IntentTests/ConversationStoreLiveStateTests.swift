import Foundation
import Observation
import Synchronization
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
        role: String = "assistant",
        block: [String: Any],
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
            params: snapshotParams(messages: [[
                "id": "msg-1",
                "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z",
            ]])
        )

        #expect(changeCount.withLock { $0 } == 1)
    }

    @Test func snapshotWithoutMetaResetsTruncationDefaults() async throws {
        let (store, _) = makeStore()

        // First snapshot marks the transcript truncated.
        store.handleStreamEvent("subscription.push", params: snapshotParams(
            messages: [
                [
                    "id": "msg-1", "role": "user",
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
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.isTruncated == false)
        #expect(store.totalMessageCount == 1)
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

    /// Agent A's page (truncated, with an in-flight assistant message) that
    /// must never land once the transcript is bound to agent B.
    private var stalePageForAgentA: [String: Any] {
        [
            "messages": [
                [
                    "id": "msg-a1", "role": "assistant",
                    "contentBlocks": [["type": "text", "id": "msg-a1:0", "text": "Stale A"]],
                    "timestamp": "2026-06-27T01:00:00.000Z",
                    "isStreaming": true
                ]
            ],
            "truncated": true,
            "totalMessages": 42
        ]
    }

    /// Rebind the store to agent B (`chat.subscribe` → `liveTranscript.subscribe`
    /// binds synchronously) and seed B's transcript from its live snapshot.
    private func rebindToAgentB(_ store: ConversationStore, _ fake: FakeConnectionManager) async {
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-chat-123"]
        await store.subscribeLiveChat(agentId: "agent-b")
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-b1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-b1:0", "text": "Hello B"]],
                "timestamp": "2026-06-27T02:00:00.000Z"
            ]
        ]))
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.isStreaming == false)
    }

    private func expectAgentBTranscriptIntact(_ store: ConversationStore) {
        #expect(store.messages.map(\.id) == ["msg-b1"])
        #expect(store.messages.first?.contentBlocks?.first?.resolvedText == "Hello B")
        #expect(store.isStreaming == false)
        #expect(store.isTruncated == false)
        #expect(store.totalMessageCount == 1)
    }

    @Test func staleFetchResolvedAfterRebindDoesNotOverwriteNewAgent() async throws {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        // Rebind while A's request is still in flight, then let A's page arrive.
        await rebindToAgentB(store, fake)
        fake.resolvePending("agent.getConversation", with: stalePageForAgentA)
        await fetchTask.value

        expectAgentBTranscriptIntact(store)
    }

    @Test func staleFetchRebindDuringDecodeDoesNotOverwriteNewAgent() async throws {
        let (store, fake) = makeStore()
        fake.pendingMethods = ["agent.getConversation"]

        let fetchTask = Task { await store.fetchConversation(agentId: "agent-a", workspaceId: "ws-1") }
        while !fake.didCallMethod("agent.getConversation") {
            await Task.yield()
        }

        // A's response arrives while A is still bound; the fetch resumes on
        // MainActor and hops off for the @concurrent decode. Rebinding to B in
        // that post-response window must still drop A's page.
        fake.resolvePending("agent.getConversation", with: stalePageForAgentA)
        await Task.yield()
        await rebindToAgentB(store, fake)
        await fetchTask.value

        expectAgentBTranscriptIntact(store)
    }

    // MARK: - Firehose gating while chat channel is live

    @Test func firehoseActivityIgnoredWhenChatLive() async throws {
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

        // Firehose stream events for the same turn must NOT mutate live state —
        // chat.subscribe owns the transcript and streaming flags while chatLive.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
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

    @Test func firehoseActivityRaisesStreamingWhenChatNotLive() async throws {
        // No chat.subscribe snapshot applied → chatLive is false (legacy fallback).
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // agent:stream:activity is content-free ({ agentId, messageId }) —
        // it must raise the streaming flag but never mutate the transcript.
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.isEmpty)
        #expect(store.isStreaming == true)
    }

    @Test func failedResubscribeClearsChatLiveSoFirehoseApplies() async throws {
        let (store, _) = makeStore()

        // Chat channel goes live via a snapshot.
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: [
            [
                "id": "msg-1", "role": "user",
                "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                "timestamp": "2026-06-27T01:00:00.000Z"
            ]
        ]))
        #expect(store.messages.count == 1)

        // A re-subscribe fails (no response configured → request throws).
        // The legacy-fallback cleanup must clear chatLive so firehose events apply.
        await store.subscribeLiveChat(agentId: "agent-1")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:start", "data": ["streamId": "s-1"]]
        ])
        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": ["messageId": "m-1"]]
        ])

        #expect(store.messages.count == 1)
        #expect(store.isStreaming == true)
    }

    // MARK: - Stale-seq tolerance

    @Test func staleSeqDeltaIgnoredWithoutResubscribe() async throws {
        let (store, fake) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Working"])
        ]))
        #expect(store.messages.count == 1)

        // Stale re-delivery: seq 1 already applied (expected is now 2) — must be
        // silently ignored, not treated as a gap
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-stale",
                        block: ["type": "text", "id": "msg-stale:0", "text": "dup"])
        ]))

        // Give any (wrongly) spawned resnapshot task a chance to run
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.messages.count == 1) // stale entity not applied
        #expect(!fake.didCallMethod("chat.unsubscribe"))
        #expect(!fake.didCallMethod("chat.subscribe"))

        // The live sequence continues normally after the stale frame
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Working more"])
        ]))
        #expect(store.messages[0].contentBlocks?.first?.resolvedText == "Working more")
    }

    @Test func gapAheadStillResnapshotsExactlyOnce() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["chat.unsubscribe"] = [String: Any]()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        // Gap: expected seq 1, got 5 — genuine loss, must resnapshot
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 5, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "lost"])
        ]))
        // A second gapped frame while the resnapshot is in flight must not
        // trigger another one (storm guard)
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 6, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:1", "text": "also lost"])
        ]))

        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.messages.isEmpty) // gapped deltas not applied
        #expect(fake.paramsForMethod("chat.unsubscribe").count == 1)
    }

    @Test func staleSnapshotRedeliveryIgnoredAfterDeltasApplied() async throws {
        let (store, fake) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Working"])
        ]))
        #expect(store.messages.count == 1)

        // A duplicate/late seq-0 snapshot after deltas were applied would rewind
        // chatExpectedSeq and roll the transcript back — it must be ignored
        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        #expect(store.messages.count == 1)
        #expect(store.messages[0].id == "msg-2")

        // The live sequence continues without a gap
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2",
                        block: ["type": "text", "id": "msg-2:0", "text": "Working more"])
        ]))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages[0].contentBlocks?.first?.resolvedText == "Working more")
        #expect(!fake.didCallMethod("chat.unsubscribe"))
    }

    // MARK: - Mid-turn tool title classification (STAB: generic spanner fallback)

    /// Daemon-shaped live `tool_use` delta: auggie sends `raw_input: null`, so the
    /// daemon coerces input to `{}` carrying only `_acpTitle` (tool_block.rs). The
    /// classifier must derive a meaningful title from `_acpTitle` instead of
    /// falling through to the generic "🔧" fallback.
    @Test func midTurnFileReadToolWithAcpTitleOnlyClassifiesAsRead() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "view",
                "input": ["_acpTitle": "Read `crates/intent-core/src/lib.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))

        let block = try #require(store.messages.first?.contentBlocks?.first)
        #expect(block.type == .toolUse)
        #expect(block.input?["_acpTitle"]?.value as? String == "Read `crates/intent-core/src/lib.rs`")

        let display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == "📄")
        #expect(display.verb == "Read")
        #expect(display.subject == "lib.rs")
        #expect(display.path == "crates/intent-core/src")
    }

    @Test func terminalToolWithAcpTitleOnlyExtractsCommand() async throws {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "_acpTitle": AnyCodable("Run `cargo test --workspace`")
        ])
        #expect(display.icon == "▶️")
        #expect(display.verb == "Run")
        #expect(display.subject == "cargo test --workspace")
    }

    @Test func workspaceApiWithAcpTitleUsesTitleAsLabel() async throws {
        let display = ToolClassifier.classify(name: "workspace_api", input: [
            "_acpTitle": AnyCodable("Read spec and task note")
        ])
        #expect(display.icon != "🔧")
        #expect(display.verb == "Read spec and task note")
    }

    @Test func unrecognizedToolWithProseAcpTitleUsesTitleVerbatim() async throws {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("Summarize recent activity for the user")
        ])
        #expect(display.verb == "Summarize recent activity for the user")
        #expect(display.subject == nil)
    }

    /// A raw tool-name-shaped title (single token) must NOT be rendered verbatim;
    /// the cleaned-name generic fallback wins (desktop isProseToolName parity).
    @Test func nonProseAcpTitleKeepsCleanedNameFallback() async throws {
        let display = ToolClassifier.classify(name: "zz_unrecognized_tool", input: [
            "_acpTitle": AnyCodable("zz_unrecognized_tool")
        ])
        #expect(display.icon == "🔧")
        #expect(display.verb == "Zz Unrecognized Tool")
    }

    @Test func readToolWithQuotedExtensionlessFilenameClassifiesAsRead() async throws {
        let display = ToolClassifier.classify(name: "view", input: [
            "_acpTitle": AnyCodable("Read `LICENSE`")
        ])
        #expect(display.icon == "📄")
        #expect(display.verb == "Read")
        #expect(display.subject == "LICENSE")
    }

    @Test func editToolWithAcpTitleOnlyExtractsPath() async throws {
        let display = ToolClassifier.classify(name: "str-replace-editor", input: [
            "_acpTitle": AnyCodable("Edit `src/foo/bar.ts`")
        ])
        #expect(display.icon == "✏️")
        #expect(display.verb == "Edit")
        #expect(display.subject == "bar.ts")
        #expect(display.path == "src/foo")
    }

    @Test func terminalKillAcpTitleUsesTitleVerbAndSubject() async throws {
        let display = ToolClassifier.classify(name: "launch-process", input: [
            "_acpTitle": AnyCodable("Kill terminal 5")
        ])
        #expect(display.icon == "▶️")
        #expect(display.verb == "Kill")
        #expect(display.subject == "terminal 5")
    }

    /// The completed `agent:tool:call` update arrives as an `updated` entity with
    /// fuller input; the store must replace the block so re-classification picks
    /// up the raw args mid-turn.
    @Test func completedUpdatedToolBlockReplacesInputAndReclassifies() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "view",
                "input": ["_acpTitle": "Read `src/main.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))
        // Title deliberately disagrees with path: raw input must win over the
        // _acpTitle fallback (pins raw-input-wins precedence).
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "view",
                "input": ["_acpTitle": "Read `other.rs`", "path": "src/main.rs"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "completed"]
            ])
        ]))

        let block = try #require(store.messages.first?.contentBlocks?.first)
        #expect(block.input?["path"]?.value as? String == "src/main.rs")

        let display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == "📄")
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")
    }

    /// Regression (bare spanner): sparse `tool_call_update` ticks reach the
    /// chat.subscribe delta path as FULL blocks with every unset field mapped
    /// to its default (`name:""`, `input:{}`, `toolKind:"other"` — see the
    /// daemon's `tool_delta`/`map_tool_call_update`). Upserting such a block
    /// verbatim clobbers the titled block from first sight, and every later
    /// sparse tick keeps it clobbered — the in-flight row renders as a bare
    /// 🔧 with no title for the rest of the turn. A progress-only tick (empty
    /// name, same toolCallId) must preserve the prior block's name/input/
    /// toolKind and only adopt the new status (desktop bridge merge parity).
    @Test func sparseProgressTickPreservesPriorToolBlockFields() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "view",
                "input": ["_acpTitle": "Read `src/main.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))

        // Sparse in-progress tick: name/input/toolKind collapse to defaults.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "started"]
            ])
        ]))

        var block = try #require(store.messages.first?.contentBlocks?.first)
        #expect(block.resolvedName == "view")
        #expect(block.input?["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata?["toolKind"]?.value as? String == "read")

        var display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == "📄")
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")

        // Sparse completion tick (status + output only) must also preserve
        // the retained fields while adopting the terminal status.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 3, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use", "id": "msg-2:0", "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "completed"]
            ])
        ]))

        block = try #require(store.messages.first?.contentBlocks?.first)
        #expect(block.resolvedName == "view")
        #expect(block.input?["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata?["status"]?.value as? String == "completed")

        display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")
    }

    // MARK: - User-row deltas (intentd#747)

    /// A persisted non-assistant row (queue drain, direct send, model switch)
    /// arrives as an authoritative `role: "user"` delta entity with
    /// `streamingComplete: true` — it must render as a user message without a
    /// refetch.
    @Test func userRowDeltaAppendsUserMessage() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-u1", role: "user",
                        block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
                        streamingComplete: true,
                        messageSeq: 3,
                        timestamp: "2026-06-27T01:00:02.000Z")
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.id == "msg-u1")
        #expect(user.role == .user)
        #expect(user.isStreaming == false)
        #expect(user.timestamp == "2026-06-27T01:00:02.000Z")
        #expect(user.contentBlocks?.count == 1)
        #expect(user.contentBlocks?.first?.resolvedText == "Queued message")
        // A user row is not turn activity: it must not raise the streaming flag.
        #expect(store.isStreaming == false)
    }

    /// Re-delivery of the same user row (same synthetic block id) upserts by
    /// id instead of duplicating the message or its blocks.
    @Test func userRowDeltaRedeliveryDoesNotDuplicate() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        let entity = blockEntity(messageId: "msg-u1", role: "user",
                                 block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
                                 streamingComplete: true)
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [entity]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [entity]))

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.contentBlocks?.count == 1)
        #expect(store.messages.first?.contentBlocks?.first?.resolvedText == "Queued message")
    }

    /// A direct send appends an optimistic local user message; the authoritative
    /// user-row delta for the same messageId (same synthetic `{messageId}:0`
    /// block id) must upsert onto it, not duplicate the message or the block.
    @Test func userRowDeltaDoesNotDuplicateOptimisticLocalAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: messageId, role: "user",
                        block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                        streamingComplete: true,
                        timestamp: "2026-06-27T01:00:02.000Z")
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.role == .user)
        #expect(user.contentBlocks?.count == 1)
        #expect(user.contentBlocks?.first?.resolvedText == "Hello")
    }

    /// An attachment send persists the text block at index 0 with attachments
    /// after (daemon `user_message_blocks`): a multi-block user-row delta must
    /// upsert its text block over the single-block optimistic append and add
    /// the attachment blocks alongside, without duplicating anything.
    @Test func multiBlockUserRowDeltaUpsertsOverOptimisticAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "See this",
                                    workspaceId: "ws-1",
                                    imageBlocks: [["type": "image", "data": "aGk=", "mimeType": "image/png"]])

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: messageId, role: "user",
                        block: ["type": "text", "id": "\(messageId):0", "text": "See this"],
                        streamingComplete: true),
            blockEntity(messageId: messageId, role: "user",
                        block: ["type": "image", "id": "\(messageId):1",
                                "data": "aGk=", "mimeType": "image/png"],
                        streamingComplete: true)
        ]))

        #expect(store.messages.count == 1)
        let blocks = try #require(store.messages.first?.contentBlocks)
        #expect(blocks.count == 2)
        #expect(blocks[0].type == .text)
        #expect(blocks[0].resolvedText == "See this")
        #expect(blocks[1].type == .image)
    }

    /// A user row's `streamingComplete: true` is row-completion, not
    /// end-of-turn: it must not clear the optimistic thinking indicator (a
    /// direct send's row lands while the indicator is up; a queue drain's row
    /// lands right before the turn's first chunk).
    @Test func userRowTerminalDeltaDoesNotClearTurnStreaming() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")
        #expect(store.isStreaming == true)

        let messageId = try #require(store.messages.first?.id)
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: messageId, role: "user",
                        block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                        streamingComplete: true)
        ]))

        #expect(store.isStreaming == true)
    }

    // MARK: - Enriched agent:stream:activity preview payload (watched agents)

    private func makeWatchedAgent(
        id: String,
        lastAgentResponse: String? = nil,
        lastUserMessage: String? = nil,
        lastMessageRole: String? = nil,
        digest: String? = nil
    ) -> AgentSession {
        AgentSession(
            id: id, name: "Delegate", status: "responding",
            isBackground: false, isStreaming: true,
            isProcessing: false, isResponding: true,
            isWaitingForOtherAgents: false, waitingForAgentIds: [],
            createdAt: nil, updatedAt: nil, lastActivity: nil,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: lastUserMessage,
            lastMessageRole: lastMessageRole,
            digest: digest, specialist: nil, createdByAgentId: nil,
            attentionRequestKind: nil, attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    /// Sets up a store whose agentId is the parent — pins that the early
    /// agent-ID filter exempts watched-agent events.
    private func makeParentStore(watching childId: String) async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["agent.getConversation"] = ["messages": []]
        await store.fetchConversation(agentId: "agent-parent", workspaceId: "ws-1")
        store.watchedAgentIds = [childId]
        store.watchedAgents = [makeWatchedAgent(id: childId, lastAgentResponse: "Old preview")]
        store.isWaitingForAgents = true
        fake.clearRequestLog()
        return (store, fake)
    }

    /// Drain the MainActor queue so any (wrongly) spawned refresh Task would
    /// have started — and logged its request — before negative assertions.
    /// Everything here is MainActor-bound and the fake resolves without delay,
    /// so yielding is deterministic (no wall-clock dependence).
    private func drainMainQueue() async {
        for _ in 0..<20 { await Task.yield() }
    }

    /// Poll (bounded) until the condition holds — avoids fixed-sleep flakiness
    /// for positive assertions on Task-spawned work.
    private func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// An enriched activity ping carrying preview fields updates the watched
    /// agent push-style — no agent.get refetch, no transcript/streaming
    /// mutation on the parent store.
    @Test func enrichedActivityAppliesPreviewToWatchedAgentWithoutRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1",
                "lastAgentResponse": "Running the tests now",
                "digest": "Running unit tests"
            ]]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Running the tests now")
        #expect(watched.digest == "Running unit tests")
        #expect(watched.displayMessage == "Running unit tests")
        #expect(!fake.didCallMethod("agent.get"))
        // Not our agent's turn — parent streaming state untouched.
        #expect(store.isStreaming == false)
        #expect(store.messages.isEmpty)
    }

    /// A partial payload (lastAgentResponse only, no digest yet) applies the
    /// present field and preserves the existing one.
    @Test func enrichedActivityPartialPayloadPreservesExistingFields() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = [makeWatchedAgent(id: "agent-child", digest: "Prior digest")]

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1",
                "lastAgentResponse": "Partial turn text"
            ]]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Partial turn text")
        #expect(watched.digest == "Prior digest")
        #expect(!fake.didCallMethod("agent.get"))
    }

    /// The symmetric partial payload (digest only) applies the digest and
    /// preserves the existing lastAgentResponse.
    @Test func enrichedActivityDigestOnlyPreservesLastAgentResponse() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1",
                "digest": "Fresh digest"
            ]]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == "Fresh digest")
        #expect(watched.displayMessage == "Fresh digest")
        #expect(!fake.didCallMethod("agent.get"))
    }

    /// A watched agent previewing a newest user message (lastMessageRole
    /// "user") switches back to the agent-side preview when live agent text
    /// arrives via the enriched ping — the applied preview flips the role to
    /// "assistant", mirroring the daemon's read-path overlay.
    @Test func enrichedActivityFlipsUserNewestPreviewToAgentText() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = [makeWatchedAgent(
            id: "agent-child",
            lastUserMessage: "Please also update the docs",
            lastMessageRole: "user"
        )]
        #expect(store.watchedAgents.first?.displayMessage == "Please also update the docs")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1",
                "lastAgentResponse": "Updating the docs now"
            ]]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastMessageRole == "assistant")
        #expect(watched.displayMessage == "Updating the docs now")
        #expect(!fake.didCallMethod("agent.get"))
    }

    /// A content-free ping for an already-loaded watched agent means no turn
    /// text is derivable yet (pre-first-token), so it neither refetches nor
    /// mutates the row — the next enriched ping or turn-end event covers it.
    @Test func contentFreeActivityForLoadedAgentDoesNotRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1"
            ]]
        ])
        await drainMainQueue()

        #expect(!fake.didCallMethod("agent.get"))
        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
    }

    /// An enriched ping for a watched agent whose details haven't loaded yet
    /// (not in watchedAgents) falls back to the refetch so the row can appear.
    @Test func enrichedActivityForUnloadedWatchedAgentFallsBackToRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = []
        fake.responseMap["agent.get"] = ["agent": [
            "id": "agent-child", "name": "Delegate", "status": "responding",
            "isStreaming": true, "lastAgentResponse": "Loaded"
        ]]

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-child", "messageId": "m-1",
                "lastAgentResponse": "Preview text", "digest": "Digest text"
            ]]
        ])
        try await waitFor { store.watchedAgents.first?.id == "agent-child" }

        #expect(fake.paramsForMethod("agent.get").count == 1)
        #expect(store.watchedAgents.first?.id == "agent-child")
    }

    /// Events from agents that are neither ours nor watched are still dropped
    /// by the early agent-ID filter.
    @Test func activityFromUnrelatedAgentStillDropped() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": ["type": "agent:stream:activity", "data": [
                "agentId": "agent-stranger", "messageId": "m-1",
                "lastAgentResponse": "Should not apply", "digest": "Nope"
            ]]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
        #expect(!fake.didCallMethod("agent.get"))
        #expect(store.isStreaming == false)
    }
}
