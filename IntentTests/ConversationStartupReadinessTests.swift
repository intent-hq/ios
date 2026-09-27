import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupReadinessTests {
    @Test func globalFeedFailureDoesNotBlockChatAndRetryReconcilesOnce() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        let model = fixture.makeViewModel()
        defer { fixture.stop() }
        await model.load()
        #expect(!model.messages.isEmpty && !model.isLoading)
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        connection.globalSubscriptionState = .failed(attempts: 5, lastError: "Feed unavailable")
        let checkpoint = connection.checkpoint
        connection.retryGlobalSubscription()
        #expect(connection.retryGlobalSubscriptionCallCount == 1)
        fixture.parentMetadata["lastSeenMessageId"] = "new-marker"
        connection.globalSubscriptionState = .subscribed
        try await waitUntil("ready feed reconciliation settles") {
            connection.traffic(since: checkpoint).calls("agent.get").count == 1
                && model.store.lastSeenMessageId == "new-marker"
                && connection.traffic(since: checkpoint).calls("agent.getSubscriptions").count == 1
                && connection.traffic(since: checkpoint).pendingCount == 0
        }
        #expect(model.hasLatchedNewMessagesDividerAnchor)
        let reconciliation = connection.traffic(since: checkpoint)
        #expect(reconciliation.methodCounts == ["agent.get": 1, "agent.getQueue": 1, "agent.getSubscriptions": 1])
        connection.globalSubscriptionState = .subscribed
        try await expectNever("another ready-feed reconciliation") {
            connection.traffic(since: checkpoint).requests.count > 3
        }
        #expect(connection.paramsForMethod("events.subscribe").allSatisfy { params in
            params["eventTypes"] as? [String] != ["agent:*"]
        })
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
    }

    @Test func readinessDuringSeedsDiscardsOldRepliesAndFoldsNewEvents() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        connection.globalSubscriptionState = .subscribing(attempt: 1)
        connection.pendingMethods = ["agent.get", "agent.getQueue", "agent.getSubscriptions"]
        let model = fixture.makeViewModel()
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        for method in ["agent.get", "agent.getQueue", "agent.getSubscriptions"] {
            try await connection.waitForPendingRequests(method)
        }
        connection.globalSubscriptionState = .subscribed
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["stale-child"]]]])
        for method in ["agent.get", "agent.getQueue", "agent.getSubscriptions"] {
            try await connection.waitForPendingRequests(method)
        }
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        #expect(!connection.didCallMethod("agent.list"))
        connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "data": ["agentId": ConversationStartupFixture.parentId, "lastSeenMessageId": "live-marker"]
        ])
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": []])
        await load.value
        #expect(model.store.lastSeenMessageId == "live-marker")
        #expect(model.hasLatchedNewMessagesDividerAnchor)
        for method in ["agent.get", "agent.getQueue", "agent.getSubscriptions"] {
            #expect(connection.paramsForMethod(method).count == 2)
        }
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
    }

    @Test func slowMetadataDoesNotHideSnapshotOrLatchAnUnrelatedMarker() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getQueue", "hook.list", "prMonitor.list", "specialist.list"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await waitUntil("early transcript") { !model.isLoading && !model.messages.isEmpty }
        #expect(!model.isEntryScrollReady)
        #expect(model.newMessagesDividerAnchorId == nil)
        connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "data": ["agentId": ConversationStartupFixture.parentId, "pendingQuestionsMessageId": ""]
        ])
        fixture.parentMetadata["specialist"] = "slow-specialist"
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("authoritative marker latch while queue/footer/catalogs are pending") {
            model.isEntryScrollReady && connection.pendingRequestCount("specialist.list") == 1
        }
        #expect(model.store.lastSeenMessageId == ConversationStartupFixture.messageId)
        #expect(model.store.pendingQuestionsMessageId?.isEmpty == true)
        #expect(model.newMessagesDividerAnchorId == nil, "latest message was already seen")
        #expect(connection.pendingRequestCount("agent.getQueue") == 1)
        #expect(connection.pendingRequestCount("hook.list") == 1)
        #expect(connection.pendingRequestCount("prMonitor.list") == 1)
    }

    @Test func subscriptionEventDuringSeedDiscardsStaleResultAndReconciles() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.getSubscriptions"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        connection.deliverEvent(method: "event", params: [
            "type": "agent:subscribed", "data": ["agentId": ConversationStartupFixture.parentId]
        ])
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["stale-child"]]]])
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        #expect(model.store.watchedAgentIds.isEmpty)
        #expect(!connection.didCallMethod("agent.list"), "stale seed must not start child resolution")
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [], "delegationGroups": []])
        await load.value
        #expect(model.store.watchedAgentIds.isEmpty)
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == 2)
    }
}
