// swiftlint:disable file_length
import Combine
import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStoreIntegrationTests {
    /// Bounded poll for work the store spawns as its own task.
    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
    }

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

        try await waitFor("chat.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Verify chat.subscribe was called and handler registered
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - First-open transcript races

    @Test func firstOpenSlowEmptyFetchClobbersNewerSnapshotAndDoesNotRetry() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.pendingMethods.insert("agent.getConversation")

        await store.subscribeLiveChat(agentId: "agent-1")
        let fetch = Task {
            await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        }
        try await fake.waitForPendingRequests("agent.getConversation")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-09-18T00:00:00Z"
                ]
            ],
            delta: nil
        ))
        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(store.isLoading)

        fake.resolvePending(
            "agent.getConversation",
            with: ["messages": [] as [[String: Any]]] as [String: Any]
        )
        await fetch.value

        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(!store.isLoading)
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        try await expectNever("an automatic conversation retry") {
            fake.paramsForMethod("agent.getConversation").count > 1
        }

        fake.pendingMethods.remove("agent.getConversation")
        fake.responseMap["agent.getConversation"] = [
            "messages": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-09-18T00:00:00Z"
                ]
            ]
        ]
        let reopenedStore = ConversationStore(connectionManager: fake)
        await reopenedStore.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        #expect(reopenedStore.messages.map(\.id) == ["msg-1"])
    }

    @Test func firstOpenDelayedEmptySnapshotClobbersFetchedConversation() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getConversation"] = [
            "messages": [
                [
                    "id": "msg-1",
                    "role": "user",
                    "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]],
                    "timestamp": "2026-09-18T00:00:00Z"
                ]
            ]
        ]

        await store.subscribeLiveChat(agentId: "agent-1")
        await store.fetchConversation(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.messages.map(\.id) == ["msg-1"])

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [],
            delta: nil
        ))

        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(!store.isLoading)
        try await fake.waitForRequests("agent.getConversation", count: 2)
        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - contiguousDeltaAdvancesState

    @Test func contiguousDeltaAdvancesState() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "id": "msg-1:0", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.messages.count == 1)

        // Contiguous block-level delta (PROTOCOL §7.1)
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .delta,
            seq: 1,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(
                added: [
                    [
                        "agentId": "agent-1",
                        "messageId": "msg-2",
                        "role": "assistant",
                        "block": ["type": "text", "id": "msg-2:0", "text": "World"]
                    ]
                ],
                updated: [],
                removedIds: []
            )
        ))

        #expect(store.messages.count == 2)
        #expect(store.messages[1].contentBlocks.first?.resolvedText == "World")
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
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.messages.count == 1)

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
        try await waitFor("resnapshot baseline refetch") {
            fake.didCallMethod("agent.getConversation")
        }

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
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

        try await waitFor("initial onReconnected flow") {
            fake.didCallMethod("agent.getSubscriptions")
        }

        // Snapshot
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [
                ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"]
            ],
            delta: nil
        ))
        #expect(store.messages.count == 1)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-2", "seq": 0, "snapshot": []]
        fake.clearRequestLog()
        fake.simulateDisconnect()
        fake.simulateConnect()

        try await waitFor("reconnect resubscribe") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        // Verify fresh subscribe + getConversation (both called from onReconnected)
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.getConversation"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - Agent Subscriptions with Top-Level actorIds

    @Test func parsesTopLevelActorIdsFromSubscriptions() async {
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
}

extension ConversationStoreIntegrationTests {
    @Test func fallsBackToFilterActorIdsForLegacyFormat() async {
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

    @Test func combinesActorIdsFromSubscriptionsAndDelegationGroups() async {
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
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1)
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
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1)
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = [
            "success": true,
            "queued": true,
            "queuedMessage": ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0]
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
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = [
            "success": true,
            "queued": true,
            "quarantined": true,
            "queuedMessage": ["id": "q-1", "content": "first", "queuedAt": "2025-01-01T00:00:00Z", "position": 0]
        ]

        try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")

        #expect(store.queuedMessages.map(\.id) == ["q-1"])
    }

    @Test func sendQueuedMessageNowNotFoundRefreshesQueueNonDestructively() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-stale", content: "stale", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "queued message not found (-32602)",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        fake.responseMap["agent.getQueue"] = [
            "queue": [
                ["id": "q-server", "content": "authoritative", "queuedAt": "2025-01-01T00:00:02Z", "position": 0]
            ]
        ]

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
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as a missing queued message
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: messageId"]
        )

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
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket",
            code: -32_603,
            userInfo: [NSLocalizedDescriptionKey: "internal error (-32603)"]
        )

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
        try await waitFor("deinit handler removal") {
            fake.eventHandlerCount == 0 && fake.subscriptionHandlerCount == 0
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(fake.subscriptionHandlerCount == 0)
    }
}
