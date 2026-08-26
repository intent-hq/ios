import Foundation
import Testing
import Combine
@testable import Intent

@MainActor
struct ConversationStoreIntegrationTests {
    
    // MARK: - subscribeOnConnect

    @Test func subscribeOnConnect() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure all responses needed for onReconnected flow
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Start connected and fetch conversation (triggers onReconnected)
        fake.simulateConnect()
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        // Yield to allow Combine publisher callbacks to run, then wait for operations
        // Wait for the subscription handler to be registered (post-completion signal)
        // rather than just the request log entry which happens at request start
        await Task.yield()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms, up to 2 seconds total
            if fake.hasSubscriptionHandler(id: "sub-1") {
                break
            }
        }

        // Verify chat.subscribe was called and handler registered
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }
    
    // MARK: - contiguousDeltaAdvancesState
    
    @Test func contiguousDeltaAdvancesState() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages.count == 1)

        // Contiguous block-level delta (PROTOCOL §7.1)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [[
                    "agentId": "agent-1",
                    "messageId": "msg-2",
                    "role": "assistant",
                    "block": ["type": "text", "id": "msg-2:0", "text": "World"]
                ]],
                updated: [],
                removedIds: []
            )
        ))
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(store.messages.count == 2)
        #expect(store.messages[1].contentBlocks?.first?.resolvedText == "World")
    }
    
    // MARK: - gapTriggersResnapshotWithBaselineRefetch
    
    @Test func gapTriggersResnapshotWithBaselineRefetch() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Set agentId by calling fetchConversation first (required for resnapshot to work)
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        
        fake.clearRequestLog()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-2", "seq": 5, "snapshot": []]

        // Two gap deltas in quick succession (seq 5/6 instead of 1) must trigger
        // exactly ONE resnapshot (storm guard)
        for seq in [5, 6] {
            fake.deliverSubscriptionPush(SubscriptionPush(
                subscriptionId: "sub-1",
                kind: .delta,
                seq: seq,
                snapshot: nil,
                delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
            ))
        }
        try await Task.sleep(nanoseconds: 200_000_000)

        // Verify resnapshot: unsubscribe, subscribe, getConversation — once each
        #expect(fake.paramsForMethod("chat.unsubscribe").count == 1)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        #expect(fake.didCallMethod("agent.getConversation"))
    }
    
    // MARK: - connectionLossClearsLiveThenReconnectResubscribes
    
    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure all responses needed for onReconnected flow
        fake.responseMap["agent.getConversation"] = ["messages": []]
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Initial setup - simulate connected and subscribe
        fake.simulateConnect()
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(subscriptionId: "sub-1", kind: .snapshot, seq: 0, snapshot: [
            ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
        ], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.messages.count == 1)

        // Disconnect
        fake.clearRequestLog()
        fake.simulateDisconnect()
        try await Task.sleep(nanoseconds: 100_000_000)

        // Reconnect (triggers onReconnected which calls everything)
        fake.simulateConnect()

        // Wait for async onReconnected operations to complete.
        // The connection state change triggers onReconnected via a Combine publisher,
        // which schedules the async task. We must yield to let the run loop dispatch
        // the sink callback and then wait for all async operations to finish.
        // Poll for the subscription handler to be registered (post-completion signal)
        // rather than just the request log which is appended at request start.
        await Task.yield()
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 50_000_000) // 50ms, up to 2 seconds total
            if fake.hasSubscriptionHandler(id: "sub-1") {
                break
            }
        }

        // Verify fresh subscribe + getConversation (both called from onReconnected)
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.getConversation"))
    }

    // MARK: - Agent Subscriptions with Top-Level actorIds

    @Test func parsesTopLevelActorIdsFromSubscriptions() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure agent.getSubscriptions response with PROTOCOL-shaped payload:
        // subscriptions with top-level actorIds (no filter object)
        fake.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [
                [
                    "id": "sub-1",
                    "agentId": "agent-parent",
                    "agentName": "Parent Agent",
                    "workspaceId": "ws-1",
                    "createdAt": "2024-01-01T00:00:00Z",
                    "oneShot": true,
                    "actorIds": ["agent-child-1"],
                    "eventTypes": ["agent:idle", "agent:failed"],
                    "description": "Waiting for agent-child-1"
                ]
            ],
            "delegationGroups": []
        ]

        // Fetch subscriptions
        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        // Assert that watchedAgentIds contains the child agent from top-level actorIds
        #expect(store.watchedAgentIds.contains("agent-child-1"))
        #expect(store.isWaitingForAgents == true)
    }

    @Test func fallsBackToFilterActorIdsForLegacyFormat() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure agent.getSubscriptions response with legacy filter.actorIds format
        fake.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [
                [
                    "id": "sub-1",
                    "agentId": "agent-parent",
                    "filter": [
                        "actorIds": ["agent-child-2"]
                    ]
                ]
            ],
            "delegationGroups": []
        ]

        // Fetch subscriptions
        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        // Assert that watchedAgentIds contains the child agent from filter.actorIds
        #expect(store.watchedAgentIds.contains("agent-child-2"))
        #expect(store.isWaitingForAgents == true)
    }

    @Test func combinesActorIdsFromSubscriptionsAndDelegationGroups() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure agent.getSubscriptions response with both subscriptions and delegation groups
        fake.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [
                [
                    "id": "sub-1",
                    "agentId": "agent-parent",
                    "actorIds": ["agent-child-1"]
                ]
            ],
            "delegationGroups": [
                [
                    "groupId": "group-1",
                    "parentAgentId": "agent-parent",
                    "awaitMode": "all",
                    "expectedAgentIds": ["agent-child-2", "agent-child-3"],
                    "completedAgentIds": [],
                    "deletedAgentIds": [],
                    "delivered": false
                ]
            ]
        ]

        // Fetch subscriptions
        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        // Assert that watchedAgentIds contains agents from both sources
        #expect(store.watchedAgentIds.contains("agent-child-1"))
        #expect(store.watchedAgentIds.contains("agent-child-2"))
        #expect(store.watchedAgentIds.contains("agent-child-3"))
        #expect(store.isWaitingForAgents == true)

        // Verify delegation group status is computed
        #expect(store.delegationGroupStatus != nil)
        #expect(store.delegationGroupStatus?.completed == 0)
        #expect(store.delegationGroupStatus?.total == 2)
    }

    // MARK: - Send queued message now (agent.sendQueuedMessageNow)

    @Test func sendQueuedMessageNowMakesSingleRPCAndPreservesRest() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1, imageBlocks: nil),
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = ["success": true, "queued": false, "messageId": "q-1"]

        try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")

        // Exactly one RPC, carrying only identifiers (the daemon owns the payload)
        let calls = fake.paramsForMethod("agent.sendQueuedMessageNow")
        #expect(calls.count == 1)
        #expect(calls.first?["agentId"] as? String == "agent-1")
        #expect(calls.first?["workspaceId"] as? String == "ws-1")
        #expect(calls.first?["messageId"] as? String == "q-1")
        #expect(calls.first?["content"] == nil)
        #expect(fake.requestLog.count == 1)

        // Only the sent entry is dropped; the rest of the queue is preserved
        #expect(store.queuedMessages.map(\.id) == ["q-2"])
    }

    /// Slot race (§5.5): the daemon could not begin the turn and restored the
    /// entry at the FRONT of its queue, reporting `queued: true`. The local
    /// entry must be kept — `agent:queue:updated` reconciles ordering.
    @Test func sendQueuedMessageNowSlotRaceKeepsEntry() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1, imageBlocks: nil),
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = [
            "success": true, "queued": true,
            "queuedMessage": ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0],
        ]

        try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")

        #expect(store.queuedMessages.map(\.id) == ["q-1", "q-2"])
        #expect(!fake.didCallMethod("agent.getQueue"))
    }

    /// Quarantined session (monorepo#840): the daemon leaves the entry queued
    /// (`queued: true, quarantined: true`); the local entry must be kept.
    @Test func sendQueuedMessageNowQuarantinedKeepsEntry() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = [
            "success": true, "queued": true, "quarantined": true,
            "queuedMessage": ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0],
        ]

        try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")

        #expect(store.queuedMessages.map(\.id) == ["q-1"])
    }

    @Test func sendQueuedMessageNowNotFoundRefreshesQueueNonDestructively() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-stale", content: "stale", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
        ]
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "queued message not found (-32602)",
                       NSError.intentErrorDataCodeKey: "not-found"])
        fake.responseMap["agent.getQueue"] = ["queue": [
            ["id": "q-server", "content": "authoritative", "queuedAt": "2025-01-01T00:00:02Z", "position": 0],
        ]]

        await #expect(throws: (any Error).self) {
            try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-stale", workspaceId: "ws-1")
        }

        // The queue was refreshed from the daemon rather than mutated locally
        #expect(fake.didCallMethod("agent.getQueue"))
        #expect(store.queuedMessages.map(\.id) == ["q-server"])
    }

    @Test func sendQueuedMessageNowBare32602PropagatesWithoutRefreshOrRemoval() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
        ]
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as a missing queued message
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: messageId"])

        await #expect(throws: (any Error).self) {
            try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")
        }

        // No refresh, no local mutation — the error just propagates
        #expect(!fake.didCallMethod("agent.getQueue"))
        #expect(store.queuedMessages.map(\.id) == ["q-1"])
    }

    @Test func sendQueuedMessageNowOtherErrorPropagatesWithoutRefreshOrRemoval() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0, imageBlocks: nil),
        ]
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket", code: -32603,
            userInfo: [NSLocalizedDescriptionKey: "internal error (-32603)"])

        await #expect(throws: (any Error).self) {
            try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")
        }

        // No refresh, no local mutation — the error just propagates
        #expect(!fake.didCallMethod("agent.getQueue"))
        #expect(store.queuedMessages.map(\.id) == ["q-1"])
    }

    // MARK: - deinit removes event + subscription handlers (monorepo#2211, monorepo#2213)

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        var store: ConversationStore? = ConversationStore(connectionManager: fake)

        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        await store?.subscribeToStreaming(agentId: "agent-1", workspaceId: "ws-1")
        await store?.subscribeLiveChat(agentId: "agent-1")
        #expect(fake.eventHandlerCount == 1)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        // deinit hops to the main actor to remove the handlers; wait for that task
        for _ in 0..<40 {
            if fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }

    // MARK: - Slim projection (PROTOCOL §5.5) + block hydration

    @Test func fetchConversationRequestsSlimProjection() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["agent.getConversation"] = ["messages": []]

        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        let params = fake.paramsForMethod("agent.getConversation")
        #expect(params.count == 1)
        #expect(params.first?["projection"] as? String == "slim")
    }

    @Test func subscribeLiveChatRequestsSlimProjection() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]

        await store.subscribeLiveChat(agentId: "agent-1")

        let params = fake.paramsForMethod("chat.subscribe")
        #expect(params.count == 1)
        #expect(params.first?["projection"] as? String == "slim")
    }

    @Test func hydrateBlockMergesFullBlockIntoTranscript() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Seed a transcript with a slim-truncated tool_result block.
        fake.responseMap["agent.getConversation"] = ["messages": [
            [
                "id": "msg-1", "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    ["type": "tool_use", "id": "b-1", "name": "read_file", "toolCallId": "tc-1"],
                    ["type": "tool_result", "id": "b-2", "toolUseId": "tc-1",
                     "output": "preview…", "outputTruncated": true, "outputBytes": 900_000],
                ],
            ]
        ]]
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.messages.first?.contentBlocks?[1].outputTruncated == true)

        // Hydrate: the daemon returns the FULL block (no truncation flags).
        fake.responseMap["agent.getMessageBlock"] = ["block": [
            "type": "tool_result", "id": "b-2", "toolUseId": "tc-1",
            "output": "the full output",
        ] as [String: Any]]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-2")

        let params = fake.paramsForMethod("agent.getMessageBlock")
        #expect(params.count == 1)
        #expect(params.first?["agentId"] as? String == "agent-1")
        #expect(params.first?["messageId"] as? String == "msg-1")
        #expect(params.first?["blockId"] as? String == "b-2")

        let hydrated = store.messages.first?.contentBlocks?[1]
        #expect(hydrated?.outputTruncated == nil)
        #expect((hydrated?.output?.value as? String) == "the full output")
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-2"))
        #expect(store.hydratingBlockKeys.isEmpty)
    }

    @Test func hydrateBlockIsSingleFlightAndCached() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["agent.getConversation"] = ["messages": [
            [
                "id": "msg-1", "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                     "output": "preview…", "outputTruncated": true],
                ],
            ]
        ]]
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        fake.responseMap["agent.getMessageBlock"] = ["block": [
            "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full",
        ] as [String: Any]]
        // Two concurrent + one repeat hydration: only ONE wire fetch.
        async let first: () = store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        async let second: () = store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        _ = await (first, second)
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")

        #expect(fake.paramsForMethod("agent.getMessageBlock").count == 1)
    }

    @Test func hydratedBlockSurvivesSlimRefetchAndSnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        let slimMessage: [String: Any] = [
            "id": "msg-1", "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
            "contentBlocks": [
                ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                 "output": "preview…", "outputTruncated": true],
            ],
        ]
        fake.responseMap["agent.getConversation"] = ["messages": [slimMessage]]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        fake.responseMap["agent.getMessageBlock"] = ["block": [
            "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full",
        ] as [String: Any]]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect((store.messages.first?.contentBlocks?.first?.output?.value as? String) == "full")

        // A slim refetch serves the truncated preview again — the hydrated
        // full block must survive the merge.
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        #expect((store.messages.first?.contentBlocks?.first?.output?.value as? String) == "full")
        #expect(store.messages.first?.contentBlocks?.first?.outputTruncated == nil)

        // Same for a chat.subscribe (re)snapshot that re-seeds the transcript.
        await store.subscribeLiveChat(agentId: "agent-1")
        try await Task.sleep(nanoseconds: 50_000_000)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1", kind: .snapshot, seq: 0,
            snapshot: [slimMessage], delta: nil))
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect((store.messages.first?.contentBlocks?.first?.output?.value as? String) == "full")
    }

    @Test func hydrateBlockFailureClearsInFlightState() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["agent.getConversation"] = ["messages": [
            [
                "id": "msg-1", "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                     "output": "preview…", "outputTruncated": true],
                ],
            ]
        ]]
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")

        fake.errorMap["agent.getMessageBlock"] = NSError(
            domain: "WebSocket", code: -32603,
            userInfo: [NSLocalizedDescriptionKey: "internal error"])
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")

        // Failure leaves the preview in place and the in-flight set empty so
        // the user can retry.
        #expect(store.hydratingBlockKeys.isEmpty)
        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.messages.first?.contentBlocks?.first?.outputTruncated == true)

        // Retry after the error succeeds.
        fake.errorMap.removeValue(forKey: "agent.getMessageBlock")
        fake.responseMap["agent.getMessageBlock"] = ["block": [
            "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full",
        ] as [String: Any]]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect((store.messages.first?.contentBlocks?.first?.output?.value as? String) == "full")
    }

    @Test func resetClearsHydrationState() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["agent.getConversation"] = ["messages": [
            [
                "id": "msg-1", "role": "assistant", "timestamp": "2024-01-01T00:00:00Z",
                "contentBlocks": [
                    ["type": "tool_result", "id": "b-1", "toolUseId": "tc-1",
                     "output": "p", "outputTruncated": true],
                ],
            ]
        ]]
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        fake.responseMap["agent.getMessageBlock"] = ["block": [
            "type": "tool_result", "id": "b-1", "toolUseId": "tc-1", "output": "full",
        ] as [String: Any]]
        await store.hydrateBlock(messageId: "msg-1", blockId: "b-1")
        #expect(store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))

        store.reset()
        #expect(!store.isBlockHydrated(messageId: "msg-1", blockId: "b-1"))
        #expect(store.hydratingBlockKeys.isEmpty)
    }
}
