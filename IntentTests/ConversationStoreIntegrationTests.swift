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
        fake.stubChatSnapshot()
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Start connected and fetch conversation (triggers onReconnected)
        fake.simulateConnect()
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.messages.isEmpty)
        #expect(!store.isLoading)

        try await waitFor("chat.subscribe handler registration") {
            fake.hasSubscriptionHandler(id: "sub-1")
        }

        // Verify chat.subscribe was called and handler registered
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }

    // MARK: - First-open transcript (chat.subscribe seq-0 snapshot only)

    /// The registration acks first; the load stays open until its seq-0
    /// snapshot lands, which is the whole transcript. No page fetch runs.
    @Test func firstOpenAwaitsTheSnapshotAndNeverFetchesAPage() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.isLoading, "an acked registration still awaits its seq-0 snapshot")
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        let wait = Task { await store.awaitLiveChatSnapshot() }
        try await waitUntil("the snapshot wait to park") { !store.liveTranscript.snapshotWaiters.isEmpty }

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [conversationRow(id: "msg-1", text: "Hello")],
            delta: nil
        ))
        await wait.value

        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(!store.isLoading)
        #expect(store.liveTranscript.snapshotWaiters.isEmpty)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        #expect(fake.requestLog.allSatisfy { $0.method.hasPrefix("chat.") }, "the transcript has no other source")
    }

    /// An empty seq-0 snapshot over an empty transcript is the authoritative
    /// (empty) transcript: the load settles and nothing re-registers.
    @Test func firstOpenEmptySnapshotIsAuthoritative() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot()

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        #expect(store.messages.isEmpty)
        #expect(!store.isLoading)
        #expect(store.liveTranscript.chatLive)
        try await expectNever("a re-registration after an accepted empty snapshot") {
            fake.paramsForMethod("chat.subscribe").count > 1
        }
    }

    /// The snapshot never comes after the ack: the wait settles at the
    /// timeout and the presumed-stale registration is replaced on the retry
    /// schedule, whose snapshot then lands.
    @Test func missingSnapshotTimesOutAndResubscribesWithBackoff() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = .milliseconds(50)
        store.liveTranscript.initialRetryDelay = .milliseconds(20)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.isLoading)
        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [conversationRow(id: "msg-1", text: "Hello")])

        await store.awaitLiveChatSnapshot()
        #expect(store.isLoading, "the load stays open across the retry")

        try await waitUntil("the replacement registration's snapshot") { store.messages.map(\.id) == ["msg-1"] }
        #expect(!store.isLoading)
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1"])
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(store.liveTranscript.nextRetryDelay == nil, "an applied snapshot resets the backoff")
    }

    /// A rejected registration self-heals on the retry schedule, doubling
    /// the delay per consecutive failure.
    @Test func rejectedSubscribeRetriesWithBackoff() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.initialRetryDelay = .milliseconds(20)
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(!store.liveTranscript.chatChannelActive)
        #expect(store.liveTranscript.nextRetryDelay == .milliseconds(40))

        try await fake.waitForRequests("chat.subscribe", count: 2)
        try await waitUntil("the second failure to schedule a longer retry") {
            store.liveTranscript.nextRetryDelay == .milliseconds(80)
        }

        fake.errorMap.removeValue(forKey: "chat.subscribe")
        fake.stubChatSnapshot(messages: [conversationRow(id: "msg-1", text: "Hello")])
        try await waitUntil("the retried registration's snapshot") { store.messages.map(\.id) == ["msg-1"] }
        #expect(!store.isLoading)
        #expect(store.liveTranscript.nextRetryDelay == nil)
    }

    /// A delayed empty snapshot over a populated transcript is rejected: the
    /// transcript is kept and a replacement registration is opened.
    @Test func delayedEmptySnapshotOverPopulatedTranscriptResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.stubChatSnapshot(messages: [conversationRow(id: "msg-1", text: "Hello")])

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
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
        try await fake.waitForRequests("chat.subscribe", count: 2)
        #expect(fake.paramsForMethod("chat.unsubscribe").count == 1)
        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
    }
}

extension ConversationStoreIntegrationTests {
    private func conversationRow(id: String, text: String) -> [String: Any] {
        [
            "id": id,
            "role": "user",
            "contentBlocks": [["type": "text", "id": "\(id):0", "text": text]],
            "timestamp": "2026-09-18T00:00:00Z"
        ]
    }

    @Test func repeatedEmptySnapshotConfirmsDeletionAfterRecovery() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: [conversationRow(id: "msg-1", text: "Hello")],
            delta: nil,
            snapshotMeta: ["truncated": true, "totalMessages": 50]
        ))
        #expect(store.isTruncated && store.totalMessageCount == 50)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-2"]
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 1,
            snapshot: [],
            delta: nil
        ))
        try await waitUntil("empty-snapshot recovery completion") {
            !store.liveTranscript.resnapshotInProgress
                && fake.paramsForMethod("chat.subscribe").count == 2
        }
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(store.messages.map(\.id) == ["msg-1"], "the rejected empty snapshot leaves the transcript alone")

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-2",
            kind: .snapshot,
            seq: 0,
            snapshot: [],
            delta: nil,
            snapshotMeta: ["truncated": false, "totalMessages": 0]
        ))
        #expect(store.messages.isEmpty)
        #expect(!store.isTruncated)
        #expect(store.totalMessageCount == 0)
        try await expectNever("another empty-snapshot recovery") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
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

    // MARK: - gapTriggersResnapshot

    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
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
        try await waitFor("resnapshot re-registration") {
            fake.hasSubscriptionHandler(id: "sub-2")
        }

        // Verify resnapshot: unsubscribe, subscribe — once each; the old
        // transcript stays until the replacement's snapshot lands.
        #expect(fake.paramsForMethod("chat.unsubscribe").count == 1)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
        #expect(store.messages.count == 1)

        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-2",
            kind: .snapshot,
            seq: 5,
            snapshot: [
                ["id": "msg-1", "role": "user", "contentBlocks": [["type": "text", "text": "Hello"]], "timestamp": "2024-01-01T00:00:00Z"],
                ["id": "msg-2", "role": "assistant", "contentBlocks": [["type": "text", "text": "Hi"]], "timestamp": "2024-01-01T00:00:01Z"]
            ],
            delta: nil
        ))
        #expect(store.messages.map(\.id) == ["msg-1", "msg-2"])
    }

    // MARK: - connectionLossClearsLiveThenReconnectResubscribes

    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        // Configure all responses needed for onReconnected flow
        fake.stubChatSnapshot()
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        // Initial setup - simulate connected and subscribe
        fake.simulateConnect()
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
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

        // Verify the fresh subscribe (from onReconnected) replaced the old
        // registration; no transcript page is fetched alongside it.
        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.get"))
        #expect(!fake.didCallMethod("agent.getConversation"))
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
