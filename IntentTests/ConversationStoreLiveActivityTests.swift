import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing

extension ConversationStoreLiveStateTests {
    @Test func sparseProgressTickPreservesPriorToolBlockFields() async throws {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "view",
                "input": ["_acpTitle": "Read `src/main.rs`"],
                "toolCallId": "call-1",
                "metadata": ["toolKind": "read", "status": "started"]
            ])
        ]))

        // Sparse in-progress tick: name/input/toolKind collapse to defaults.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "started"]
            ])
        ]))

        var block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.resolvedName == "view")
        #expect(block.input["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata["toolKind"]?.value as? String == "read")

        var display = ToolClassifier.classify(name: block.resolvedName ?? "tool", input: block.input)
        #expect(display.icon == "📄")
        #expect(display.verb == "Read")
        #expect(display.subject == "main.rs")

        // Sparse completion tick (status + output only) must also preserve
        // the retained fields while adopting the terminal status.
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 3, updated: [
            blockEntity(messageId: "msg-2", block: [
                "type": "tool_use",
                "id": "msg-2:0",
                "name": "",
                "input": [String: Any](),
                "toolCallId": "call-1",
                "metadata": ["toolKind": "other", "status": "completed"]
            ])
        ]))

        block = try #require(store.messages.first?.contentBlocks.first)
        #expect(block.resolvedName == "view")
        #expect(block.input["_acpTitle"]?.value as? String == "Read `src/main.rs`")
        #expect(block.metadata["status"]?.value as? String == "completed")

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
            blockEntity(
                messageId: "msg-u1",
                block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
                role: "user",
                streamingComplete: true,
                messageSeq: 3,
                timestamp: "2026-06-27T01:00:02.000Z"
            )
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.id == "msg-u1")
        #expect(user.role == .user)
        #expect(user.isStreaming == false)
        #expect(user.timestamp == "2026-06-27T01:00:02.000Z")
        #expect(user.contentBlocks.count == 1)
        #expect(user.contentBlocks.first?.resolvedText == "Queued message")
        // A user row is not turn activity: it must not raise the streaming flag.
        #expect(store.isStreaming == false)
    }

    /// Re-delivery of the same user row (same synthetic block id) upserts by
    /// id instead of duplicating the message or its blocks.
    @Test func userRowDeltaRedeliveryDoesNotDuplicate() async {
        let (store, _) = makeStore()

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))

        let entity = blockEntity(
            messageId: "msg-u1",
            block: ["type": "text", "id": "msg-u1:0", "text": "Queued message"],
            role: "user",
            streamingComplete: true
        )
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [entity]))
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 2, updated: [entity]))

        #expect(store.messages.count == 1)
        #expect(store.messages.first?.contentBlocks.count == 1)
        #expect(store.messages.first?.contentBlocks.first?.resolvedText == "Queued message")
    }

    /// A direct send appends an optimistic local user message; the authoritative
    /// user-row delta for the same messageId (same synthetic `{messageId}:0`
    /// block id) must upsert onto it, not duplicate the message or the block.
    @Test func userRowDeltaDoesNotDuplicateOptimisticLocalAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                role: "user",
                streamingComplete: true,
                timestamp: "2026-06-27T01:00:02.000Z"
            )
        ]))

        #expect(store.messages.count == 1)
        let user = try #require(store.messages.first)
        #expect(user.role == .user)
        #expect(user.contentBlocks.count == 1)
        #expect(user.contentBlocks.first?.resolvedText == "Hello")
    }

    /// An attachment send persists the text block at index 0 with attachments
    /// after (daemon `user_message_blocks`): a multi-block user-row delta must
    /// upsert its text block over the single-block optimistic append and add
    /// the attachment blocks alongside, without duplicating anything.
    @Test func multiBlockUserRowDeltaUpsertsOverOptimisticAppend() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(
            agentId: "agent-1",
            content: "See this",
            workspaceId: "ws-1",
            imagePayload: .attachments([["type": "image", "data": "aGk=", "mimeType": "image/png"]])
        )

        #expect(store.messages.count == 1)
        let messageId = try #require(store.messages.first?.id)

        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "See this"],
                role: "user",
                streamingComplete: true
            ),
            blockEntity(
                messageId: messageId,
                block: [
                    "type": "image",
                    "id": "\(messageId):1",
                    "data": "aGk=",
                    "mimeType": "image/png"
                ],
                role: "user",
                streamingComplete: true
            )
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
}

extension ConversationStoreLiveStateTests {
    @Test func userRowTerminalDeltaDoesNotClearTurnStreaming() async throws {
        let (store, fake) = makeStore()
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]

        store.handleStreamEvent("subscription.push", params: snapshotParams(messages: []))
        try await store.sendMessage(agentId: "agent-1", content: "Hello", workspaceId: "ws-1")
        #expect(store.isStreaming == true)

        let messageId = try #require(store.messages.first?.id)
        store.handleStreamEvent("subscription.push", params: deltaParams(seq: 1, added: [
            blockEntity(
                messageId: messageId,
                block: ["type": "text", "id": "\(messageId):0", "text": "Hello"],
                role: "user",
                streamingComplete: true
            )
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
            id: id,
            name: "Delegate",
            status: "responding",
            isBackground: false,
            isStreaming: true,
            isProcessing: false,
            isResponding: true,
            isWaitingForOtherAgents: false,
            waitingForAgentIds: [],
            createdAt: nil,
            updatedAt: nil,
            lastActivity: nil,
            lastAgentResponse: lastAgentResponse,
            lastUserMessage: lastUserMessage,
            lastMessageRole: lastMessageRole,
            digest: digest,
            specialist: nil,
            createdByAgentId: nil,
            attentionRequestKind: nil,
            attentionRequestReason: nil,
            attentionRequestTimestamp: nil
        )
    }

    /// Sets up a store whose agentId is the parent — pins that the early
    /// agent-ID filter exempts watched-agent events.
    private func makeParentStore(watching childId: String) async -> (ConversationStore, FakeConnectionManager) {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot()
        await store.subscribeLiveChat(agentId: "agent-parent", workspaceId: "ws-1")
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
        let drainYieldCount = 20
        for _ in 0..<drainYieldCount { await Task.yield() }
    }

    /// Poll (bounded) until the condition holds — avoids fixed-sleep flakiness
    /// for positive assertions on Task-spawned work.
    private func waitFor(_ condition: () -> Bool) async throws {
        let conditionCheckLimit = 200
        let retryDelayNanoseconds: UInt64 = 10_000_000
        for _ in 0..<conditionCheckLimit {
            if condition() { return }
            try await Task.sleep(nanoseconds: retryDelayNanoseconds)
        }
    }

    /// An enriched activity ping carrying preview fields updates the watched
    /// agent push-style — no agent.get refetch, no transcript/streaming
    /// mutation on the parent store.
    @Test func enrichedActivityAppliesPreviewToWatchedAgentWithoutRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Running the tests now",
                    "digest": "Running unit tests"
                ]
            ]
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
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Partial turn text"
                ]
            ]
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
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "digest": "Fresh digest"
                ]
            ]
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
        store.watchedAgents = [
            makeWatchedAgent(
                id: "agent-child",
                lastUserMessage: "Please also update the docs",
                lastMessageRole: "user"
            )
        ]
        #expect(store.watchedAgents.first?.displayMessage == "Please also update the docs")

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Updating the docs now"
                ]
            ]
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
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1"
                ]
            ]
        ])
        await drainMainQueue()

        #expect(!fake.didCallMethod("agent.get"))
        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
    }

    /// An enriched ping for a watched agent whose details haven't loaded yet
    /// (not in watchedAgents) falls back to the refetch so the row can appear.
}

extension ConversationStoreLiveStateTests {
    @Test func enrichedActivityForUnloadedWatchedAgentFallsBackToRefetch() async throws {
        let (store, fake) = await makeParentStore(watching: "agent-child")
        store.watchedAgents = []
        fake.responseMap["agent.get"] = [
            "agent": [
                "id": "agent-child",
                "name": "Delegate",
                "status": "responding",
                "isStreaming": true,
                "lastAgentResponse": "Loaded"
            ]
        ]

        store.handleStreamEvent("event", params: [
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-child",
                    "messageId": "m-1",
                    "lastAgentResponse": "Preview text",
                    "digest": "Digest text"
                ]
            ]
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
            "event": [
                "type": "agent:stream:activity", "data": [
                    "agentId": "agent-stranger",
                    "messageId": "m-1",
                    "lastAgentResponse": "Should not apply",
                    "digest": "Nope"
                ]
            ]
        ])
        await drainMainQueue()

        let watched = try #require(store.watchedAgents.first)
        #expect(watched.lastAgentResponse == "Old preview")
        #expect(watched.digest == nil)
        #expect(!fake.didCallMethod("agent.get"))
        #expect(store.isStreaming == false)
    }
}
