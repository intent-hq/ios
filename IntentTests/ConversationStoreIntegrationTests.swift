import Combine
import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStoreIntegrationTests {
    private func waitFor(_ description: String, _ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for \(description)")
    }

    @Test(arguments: [0, 3, 50])
    func firstOpenAwaitsTheSnapshotAndNeverFetchesAPage(messageCount: Int) async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.isLoading, "an acked registration still awaits its seq-0 snapshot")
        #expect(store.loadingStage == .receiving)
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))
        let wait = Task { await store.awaitLiveChatSnapshot() }
        try await waitUntil("the snapshot wait to park") { !store.liveTranscript.snapshotWaiters.isEmpty }

        let messageIds = (0..<messageCount).map { "msg-\($0)" }
        fake.deliverSubscriptionPush(SubscriptionPush(
            subscriptionId: "sub-1",
            kind: .snapshot,
            seq: 0,
            snapshot: messageIds.map { conversationRow(id: $0, text: "Hello") },
            delta: nil
        ))
        await wait.value

        #expect(store.messages.map(\.id) == messageIds)
        #expect(store.totalMessageCount == messageCount)
        #expect(!store.isLoading)
        #expect(store.loadingStage == .idle)
        #expect(store.liveTranscript.snapshotWaiters.isEmpty)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
        #expect(fake.paramsForMethod("chat.subscribe").first?["limit"] as? Int == 50)
        #expect(fake.requestLog.allSatisfy { $0.method.hasPrefix("chat.") }, "the transcript has no other source")
    }

    @Test func firstOpenEmptySnapshotIsAuthoritative() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot()

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")

        #expect(store.messages.isEmpty)
        #expect(!store.isLoading)
        #expect(store.loadingStage == .idle, "a buffered snapshot must not be overwritten by the ack")
        #expect(store.liveTranscript.chatLive)
        try await expectNever("a re-registration after an accepted empty snapshot") {
            fake.paramsForMethod("chat.subscribe").count > 1
        }
    }

    @Test func missingSnapshotTimesOutAndResubscribesWithBackoff() async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = .milliseconds(50)
        store.liveTranscript.initialRetryDelay = .milliseconds(20)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.isLoading)
        fake.pendingMethods = ["chat.unsubscribe", "chat.subscribe"]
        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [conversationRow(id: "msg-1", text: "Hello")])

        await store.awaitLiveChatSnapshot()
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(store.loadingStage == .retrying(attempt: 2))
        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await fake.waitForPendingRequests("chat.subscribe")
        #expect(store.isLoading, "the load stays open across the retry")

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-2"])
        try await waitUntil("the replacement registration's snapshot") { store.messages.map(\.id) == ["msg-1"] }
        #expect(!store.isLoading)
        #expect(fake.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == ["sub-1"])
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        #expect(fake.paramsForMethod("chat.subscribe").allSatisfy { $0["limit"] as? Int == 50 })
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(store.liveTranscript.nextRetryDelay == nil, "an applied snapshot resets the backoff")
        #expect(!fake.didCallMethod("agent.getConversation"), "the timeout retries the channel, it never fetches")
    }

    @Test func rejectedSubscribeRetriesWithBackoff() async throws {
        let fake = FakeConnectionManager()
        fake.connectionState = .connected
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.initialRetryDelay = .milliseconds(20)
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(!store.liveTranscript.chatChannelActive)
        #expect(store.loadingStage == .retrying(attempt: 2))
        #expect(store.liveTranscript.nextRetryDelay == .milliseconds(40))

        try await fake.waitForRequests("chat.subscribe", count: 2)
        try await waitUntil("the second failure to schedule a longer retry") {
            store.liveTranscript.nextRetryDelay == .milliseconds(80)
        }
        #expect(store.loadingStage == .retrying(attempt: 3))

        fake.errorMap.removeValue(forKey: "chat.subscribe")
        fake.stubChatSnapshot(messages: [conversationRow(id: "msg-1", text: "Hello")])
        try await waitUntil("the retried registration's snapshot") { store.messages.map(\.id) == ["msg-1"] }
        #expect(!store.isLoading)
        #expect(store.liveTranscript.nextRetryDelay == nil)
        #expect(fake.paramsForMethod("chat.subscribe").allSatisfy { $0["limit"] as? Int == 50 })
        #expect(!fake.didCallMethod("agent.getConversation"), "a rejected registration retries, it never fetches")

        store.reset()
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)
        await store.subscribeLiveChat(agentId: "agent-2", workspaceId: "ws-1")
        #expect(store.loadingStage == .retrying(attempt: 2), "a new load starts its attempt count over")
        store.reset()
    }

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

    @Test func contiguousDeltaAdvancesState() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

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

    @Test func gapTriggersResnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot()
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

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

    @Test func connectionLossClearsLiveThenReconnectResubscribes() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        fake.stubChatSnapshot()
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.responseMap["agent.getQueue"] = ["queue": []]
        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.getSubscriptions"] = ["subscriptions": [], "delegationGroups": []]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        store.subscribeToStreaming(agentId: "agent-1", workspaceId: "ws-1")
        fake.simulateConnect()
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(fake.hasSubscriptionHandler(id: "sub-1"))

        try await waitFor("initial onReconnected flow") {
            fake.didCallMethod("agent.getSubscriptions")
        }

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

        try await waitFor("reconnect subscription and independent metadata request") {
            fake.hasSubscriptionHandler(id: "sub-2") && fake.didCallMethod("agent.get")
        }

        #expect(fake.didCallMethod("chat.subscribe"))
        #expect(fake.didCallMethod("agent.get"))
        #expect(!fake.didCallMethod("agent.getConversation"))
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))
    }

    @Test func parsesTopLevelActorIdsFromSubscriptions() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

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

        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        #expect(store.watchedAgentIds.contains("agent-child-1"))
        #expect(store.isWaitingForAgents == true)
    }
}

extension ConversationStoreIntegrationTests {
    @Test func fallsBackToFilterActorIdsForLegacyFormat() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

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

        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        #expect(store.watchedAgentIds.contains("agent-child-2"))
        #expect(store.isWaitingForAgents == true)
    }

    @Test func combinesActorIdsFromSubscriptionsAndDelegationGroups() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

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

        await store.fetchSubscriptions(agentId: "agent-parent", workspaceId: "ws-1")

        #expect(store.watchedAgentIds.contains("agent-child-1"))
        #expect(store.watchedAgentIds.contains("agent-child-2"))
        #expect(store.watchedAgentIds.contains("agent-child-3"))
        #expect(store.isWaitingForAgents == true)

        #expect(store.delegationGroupStatus != nil)
        #expect(store.delegationGroupStatus?.completed == 0)
        #expect(store.delegationGroupStatus?.total == 2)
    }

    @Test func sendQueuedMessageNowMakesSingleRPCAndPreservesRest() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0),
            QueuedMessage(id: "q-2", content: "second", queuedAt: "2025-01-01T00:00:01Z", position: 1)
        ]
        fake.responseMap["agent.sendQueuedMessageNow"] = ["success": true, "queued": false, "messageId": "q-1"]

        try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")

        let calls = fake.paramsForMethod("agent.sendQueuedMessageNow")
        #expect(calls.count == 1)
        #expect(calls.first?["agentId"] as? String == "agent-1")
        #expect(calls.first?["workspaceId"] as? String == "ws-1")
        #expect(calls.first?["messageId"] as? String == "q-1")
        #expect(calls.first?["content"] == nil)
        #expect(fake.requestLog.count == 1)

        #expect(store.queuedMessages.map(\.id) == ["q-2"])
    }

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

        #expect(fake.didCallMethod("agent.getQueue"))
        #expect(store.queuedMessages.map(\.id) == ["q-server"])
    }

    @Test func sendQueuedMessageNowBare32602PropagatesWithoutRefreshOrRemoval() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)

        store.queuedMessages = [
            QueuedMessage(id: "q-1", content: "first", queuedAt: "2025-01-01T00:00:00Z", position: 0)
        ]
        fake.errorMap["agent.sendQueuedMessageNow"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: messageId"]
        )

        await #expect(throws: (any Error).self) {
            try await store.sendQueuedMessageNow(agentId: "agent-1", messageId: "q-1", workspaceId: "ws-1")
        }

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

        #expect(!fake.didCallMethod("agent.getQueue"))
        #expect(store.queuedMessages.map(\.id) == ["q-1"])
    }

    @Test func deinitRemovesEventHandler() async throws {
        let fake = FakeConnectionManager()
        #expect(fake.eventHandlerCount == 0)
        var store: ConversationStore? = ConversationStore(connectionManager: fake)
        weak var detailOwner = store?.commands.agentDetails
        let detailHandlerCount = fake.eventHandlerCount
        #expect(detailHandlerCount == 1, "the standalone store owns its fallback detail listener")
        #expect(store?.eventHandlerId == nil, "streaming has not registered yet")

        fake.responseMap["events.subscribe"] = ["subscriptionId": "sub-streaming"]
        fake.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1", "seq": 0, "snapshot": []]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        store?.subscribeToStreaming(agentId: "agent-1", workspaceId: "ws-1")
        await store?.subscribeLiveChat(agentId: "agent-1")
        #expect(fake.eventHandlerCount == detailHandlerCount + 1)
        #expect(store?.eventHandlerId != nil)
        #expect(fake.subscriptionHandlerCount == 1)

        store = nil
        try await waitFor("deinit handler removal") {
            fake.eventHandlerCount == 0
                && fake.subscriptionHandlerCount == 0
                && fake.paramsForMethod("chat.unsubscribe").count == 1
        }
        #expect(fake.eventHandlerCount == 0)
        #expect(detailOwner == nil, "deinit releases the fallback detail listener too")
        #expect(fake.subscriptionHandlerCount == 0)
        #expect(fake.paramsForMethod("chat.unsubscribe").first?["subscriptionId"] as? String == "sub-1")
        #expect(!fake.didCallMethod("events.subscribe") && !fake.didCallMethod("events.unsubscribe"))
    }

    @Test func streamingDeactivationIsIdempotentAndBackendLocal() {
        let fakeA = FakeConnectionManager()
        let fakeB = FakeConnectionManager()
        fakeA.responseMap["events.subscribe"] = ["subscriptionId": "sub-a"]
        fakeA.responseMap["events.unsubscribe"] = [:] as [String: Any]
        fakeB.responseMap["events.subscribe"] = ["subscriptionId": "sub-b"]
        fakeB.responseMap["events.unsubscribe"] = [:] as [String: Any]
        let detailsA = AgentDetailStore(connection: fakeA)
        let detailsB = AgentDetailStore(connection: fakeB)
        let detailHandlersA = fakeA.eventHandlerCount
        let detailHandlersB = fakeB.eventHandlerCount
        #expect(detailHandlersA == 1 && detailHandlersB == 1, "each backend owns one detail listener")
        let storeA = ConversationStore(connectionManager: fakeA, agentDetails: detailsA)
        let storeB = ConversationStore(connectionManager: fakeB, agentDetails: detailsB)
        #expect(fakeA.eventHandlerCount == detailHandlersA && fakeB.eventHandlerCount == detailHandlersB)
        storeA.subscribeToStreaming(agentId: "agent-a", workspaceId: "ws-a")
        storeB.subscribeToStreaming(agentId: "agent-b", workspaceId: "ws-b")

        storeA.deactivateStreaming()
        storeA.deactivateStreaming()

        #expect(!fakeA.didCallMethod("events.subscribe") && !fakeA.didCallMethod("events.unsubscribe"))
        #expect(storeA.eventHandlerId == nil && !storeA.streamingEventsActive)
        #expect(storeB.eventHandlerId != nil && storeB.streamingEventsActive)
        #expect(fakeA.eventHandlerCount == detailHandlersA, "only backend A's session detail listener remains")
        #expect(fakeB.eventHandlerCount == detailHandlersB + 1, "backend B keeps its streaming listener")
        #expect(fakeB.paramsForMethod("events.unsubscribe").isEmpty)
    }

    @Test func localStreamingBindingIsSynchronousAndReappearanceHasANewOwner() {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        let sessionHandlers = fake.eventHandlerIDs
        store.bindStreaming(agentId: "agent-1", workspaceId: "ws-1")
        let oldHandler = store.eventHandlerId
        #expect(oldHandler.map { fake.eventHandlerIDs.contains($0) } == true)
        store.deactivateStreaming()
        #expect(fake.eventHandlerIDs == sessionHandlers)
        store.bindStreaming(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.eventHandlerId != oldHandler)
        #expect(fake.requestLog.isEmpty, "local ownership never issues an event subscription")
        store.deactivateStreaming()
        #expect(fake.eventHandlerIDs == sessionHandlers)
    }

    @Test func staleReconnectCannotPublishSeedsAfterReappearance() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.stubChatSnapshot(subscriptionId: "chat-reconnect")
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]
        fake.responseMap["agent.get"] = ["agent": ["isStreaming": false]]
        fake.pendingMethods = ["agent.getQueue", "agent.getSubscriptions"]
        store.bindStreaming(agentId: "agent-1", workspaceId: "ws-1")
        let reconnect = Task { await store.onReconnected() }
        try await fake.waitForPendingRequests("agent.getQueue")
        try await fake.waitForPendingRequests("agent.getSubscriptions")
        store.deactivateStreaming()
        store.bindStreaming(agentId: "new-agent", workspaceId: "new-workspace")
        let newHandler = store.eventHandlerId
        fake.resolvePending("agent.getQueue", with: ["queue": [["id": "old", "content": "stale", "queuedAt": "2026-09-27", "position": 0]]])
        fake.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["stale-child"]]]])
        await reconnect.value
        #expect(store.eventHandlerId == newHandler)
        #expect(store.queuedMessages.isEmpty && store.watchedAgentIds.isEmpty)
        #expect(!fake.didCallMethod("agent.list"))
        #expect(!fake.didCallMethod("events.subscribe"))
        #expect(fake.paramsForMethod("agent.getQueue").count == 1)
        #expect(fake.paramsForMethod("agent.getSubscriptions").count == 1)
    }
}

extension ConversationStoreIntegrationTests {
    private func emptyDelta(subscriptionId: String, seq: Int) -> SubscriptionPush {
        SubscriptionPush(
            subscriptionId: subscriptionId,
            kind: .delta,
            seq: seq,
            snapshot: nil,
            delta: SubscriptionPush.DeltaPayload(added: [], updated: [], removedIds: [])
        )
    }

    @Test func resnapshotPendingInUnsubscribeCancelsTheOldSnapshotTimeout() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = .milliseconds(20)
        store.liveTranscript.initialRetryDelay = .milliseconds(10)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]
        fake.pendingMethods = ["chat.unsubscribe"]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        #expect(store.liveTranscript.snapshotTimeoutTask != nil, "the ack arms the snapshot timeout")

        fake.deliverSubscriptionPush(emptyDelta(subscriptionId: "sub-1", seq: 3))
        try await fake.waitForPendingRequests("chat.unsubscribe")
        #expect(store.liveTranscript.resnapshotInProgress)
        #expect(store.liveTranscript.snapshotTimeoutTask == nil)
        try await expectNever("a retry registration while the recovery is pending") {
            fake.paramsForMethod("chat.subscribe").count > 1
        }

        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [conversationRow(id: "msg-1", text: "Hello")])
        fake.resolvePending("chat.unsubscribe", with: [String: Any]())
        try await waitUntil("the replacement registration's snapshot") { store.messages.map(\.id) == ["msg-1"] }
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        #expect(!store.liveTranscript.resnapshotInProgress)
        try await expectNever("a second replacement registration") {
            fake.paramsForMethod("chat.subscribe").count > 2
        }
    }

    @Test func snapshotWaitSurvivesARejectedRegistrationUntilTheRetrySnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.initialRetryDelay = .milliseconds(10)
        fake.pendingMethods = ["chat.subscribe"]
        fake.responseMap["chat.unsubscribe"] = [:] as [String: Any]

        let subscribe = Task { await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1") }
        try await fake.waitForPendingRequests("chat.subscribe")
        let wait = Task { await store.awaitLiveChatSnapshot() }
        try await waitUntil("the snapshot wait to park") { !store.liveTranscript.snapshotWaiters.isEmpty }
        #expect(store.isLoading)

        fake.failPending("chat.subscribe", with: NSError(domain: "WebSocket", code: -32_000))
        await subscribe.value
        #expect(!store.liveTranscript.chatChannelActive)
        #expect(store.isLoading)
        #expect(!store.liveTranscript.snapshotWaiters.isEmpty, "the rejection does not settle the wait")

        try await fake.waitForPendingRequests("chat.subscribe")
        #expect(fake.paramsForMethod("chat.subscribe").count == 2, "the retry re-registers the same binding")
        #expect(!store.liveTranscript.snapshotWaiters.isEmpty, "the wait parks across the held retry")

        fake.resolvePending("chat.subscribe", with: ["subscriptionId": "sub-1"])
        try await waitUntil("the retried registration's handler") { fake.hasSubscriptionHandler(id: "sub-1") }
        #expect(store.liveTranscript.chatChannelActive)
        #expect(store.isLoading, "the retried registration still awaits its seq-0 snapshot")
        #expect(!store.liveTranscript.snapshotWaiters.isEmpty, "the ack alone does not settle the wait")

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
    }

    @Test func snapshotWaitIsBoundedAcrossRejectedRegistrations() async {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        store.liveTranscript.snapshotTimeout = .milliseconds(50)
        store.liveTranscript.initialRetryDelay = .seconds(10)
        fake.errorMap["chat.subscribe"] = NSError(domain: "WebSocket", code: -32_000)

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        let start = ContinuousClock.now
        await store.awaitLiveChatSnapshot()

        #expect(ContinuousClock.now - start >= .milliseconds(40), "the wait parks until its deadline")
        #expect(store.liveTranscript.snapshotWaiters.isEmpty)
        #expect(store.liveTranscript.retryTask != nil, "the retry schedule outlives the settled wait")
        #expect(store.isLoading)
        #expect(fake.paramsForMethod("chat.subscribe").count == 1)
    }

    @Test func snapshotWaitSurvivesAReconnectUntilTheReconnectSnapshot() async throws {
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        fake.responseMap["chat.subscribe"] = ["subscriptionId": "sub-1"]

        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        let wait = Task { await store.awaitLiveChatSnapshot() }
        try await waitUntil("the snapshot wait to park") { !store.liveTranscript.snapshotWaiters.isEmpty }

        store.liveTranscript.prepareForReconnect()
        #expect(!store.liveTranscript.snapshotWaiters.isEmpty, "the outage does not settle the wait")
        #expect(!fake.hasSubscriptionHandler(id: "sub-1"))

        fake.stubChatSnapshot(subscriptionId: "sub-2", messages: [conversationRow(id: "msg-1", text: "Hello")])
        await store.subscribeLiveChat(agentId: "agent-1", workspaceId: "ws-1")
        await wait.value
        #expect(store.messages.map(\.id) == ["msg-1"])
        #expect(!store.isLoading)
        #expect(fake.hasSubscriptionHandler(id: "sub-2"))
        #expect(fake.paramsForMethod("chat.subscribe").count == 2)
        #expect(fake.paramsForMethod("chat.subscribe").allSatisfy { $0["limit"] as? Int == 50 })
    }
}
