import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupWorkspaceTests {
    @Test func aScopedEventCanRecoverWorkspaceAuthorityAfterAFailedSeed() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        connection.deliverEvent(method: "event", params: [
            "type": "agent:queue:updated", "workspaceId": ConversationStartupFixture.workspaceId,
            "data": [
                "agentId": ConversationStartupFixture.parentId,
                "queue": [["id": "queued", "content": "Keep", "queuedAt": "2026-09-27", "position": 0]]
            ]
        ])
        try await waitUntil("buffered workspace event joins metadata read") { !model.store.metadataRefreshTasks.isEmpty }
        try await expectNever("a second metadata seed while the first is held") { connection.paramsForMethod("agent.get").count > 1 }
        connection.failPending("agent.get", with: NSError(domain: "Network", code: 1))
        await load.value
        try await waitUntil("failed metadata callers settle") { model.store.metadataRefreshTasks.isEmpty }
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "workspaceId": ConversationStartupFixture.workspaceId,
            "data": ["agentId": ConversationStartupFixture.parentId, "lastSeenMessageId": "recovered"]
        ])
        try await connection.waitForPendingRequests("agent.get")
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("entry readiness recovers") { model.isEntryScrollReady }
        #expect(model.store.lastSeenMessageId == ConversationStartupFixture.messageId, "the later successful read supersedes the recovery-triggering event")
        #expect(model.store.queuedMessages.map(\.id) == ["queued"])
        #expect(connection.paramsForMethod("agent.get").count == 2)
    }

    @Test func workspaceCorrectionDropsTheOldSubscriptionSeedBeforeChildResolution() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get", "agent.getSubscriptions"]
        let stale = fixture.makeViewModel(workspaceId: "old-workspace")
        let valid = fixture.makeViewModel()
        let staleLoad = Task { await stale.load() }
        defer { staleLoad.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        let validLoad = Task { await valid.load() }
        defer { validLoad.cancel() }
        try await waitUntil("valid window has a lease") { valid.store.consumers.contains(valid.conversationConsumer) }
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("workspace authority applied") { valid.store.workspaceId == ConversationStartupFixture.workspaceId }
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["wrong-scope-child"]]]])
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        #expect(connection.paramsForMethod("agent.getSubscriptions").last?["workspaceId"] as? String == ConversationStartupFixture.workspaceId)
        #expect(!connection.didCallMethod("agent.list"))
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": []])
        await staleLoad.value
        await validLoad.value
        #expect(valid.store.watchedAgentIds.isEmpty)
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == 2)
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
    }

    @Test func scopedEventsAwaitWorkspaceAuthorityWithoutLosingTheMatchingPatch() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        for (workspace, marker) in [(ConversationStartupFixture.workspaceId, "right"), ("wrong-workspace", "wrong")] {
            connection.deliverEvent(method: "event", params: [
                "type": "agent:updated", "workspaceId": workspace,
                "data": ["agentId": ConversationStartupFixture.parentId, "lastSeenMessageId": marker]
            ])
        }
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        #expect(model.store.lastSeenMessageId == "right")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId)?.metadata["lastSeenMessageId"] as? String == "right")
        #expect(model.hasLatchedNewMessagesDividerAnchor)
        #expect(connection.paramsForMethod("agent.get").count == 1)
    }

    @Test(arguments: [false, true])
    func workspaceHintsCannotReplaceAnotherWindowsChannel(staleFirst: Bool) async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let valid = fixture.makeViewModel()
        let stale = fixture.makeViewModel(workspaceId: "stale-workspace")
        let first = staleFirst ? stale : valid
        let second = staleFirst ? valid : stale
        let firstLoad = Task { await first.load() }
        defer { firstLoad.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        try await waitUntil("first chat snapshot before workspace authority") { !first.messages.isEmpty }
        let registration = try #require(first.store.liveTranscript.chatSubscriptionId)
        let secondLoad = Task { await second.load() }
        defer { secondLoad.cancel() }
        try await waitUntil("both windows activated") { second.activeLiveStoreActivation != nil }
        #expect(first.store === second.store)
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await firstLoad.value
        await secondLoad.value
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
        #expect(connection.paramsForMethod("agent.get").count == 1)
        #expect(connection.paramsForMethod("agent.get").first?["workspaceId"] == nil)
        #expect(valid.store.workspaceId == ConversationStartupFixture.workspaceId)
        #expect(stale.agentNotFound && !valid.agentNotFound, "workspace validation is per window")
        #expect(!stale.store.consumers.contains(stale.conversationConsumer))
        #expect(valid.store.consumers.contains(valid.conversationConsumer))
        #expect(valid.store.liveTranscript.chatSubscriptionId == registration)
        #expect(connection.hasSubscriptionHandler(id: registration))
        #expect(!connection.didCallMethod("chat.unsubscribe"))
        stale.teardownLiveStores()
        #expect(connection.hasSubscriptionHandler(id: registration))
        valid.teardownLiveStores()
        try await waitUntil("final shared channel cleanup") {
            connection.traffic().calls("chat.unsubscribe").first?.completed != nil
        }
        #expect(connection.paramsForMethod("chat.unsubscribe").compactMap { $0["subscriptionId"] as? String } == [registration])
    }

    @Test func aCachedWorkspaceMismatchDoesNotAcquireOrReleaseTheValidWindow() async {
        let fixture = ConversationStartupFixture()
        let valid = fixture.makeViewModel()
        defer { fixture.stop() }
        await valid.load()
        let store = valid.store
        let registration = store.liveTranscript.chatSubscriptionId
        let checkpoint = fixture.connection.checkpoint
        let stale = fixture.makeViewModel(workspaceId: "stale-workspace")
        await stale.load()
        #expect(stale.store === store)
        #expect(stale.agentNotFound)
        #expect(store.consumers == [valid.conversationConsumer])
        #expect(store.liveTranscript.chatSubscriptionId == registration)
        #expect(fixture.connection.traffic(since: checkpoint).requests.isEmpty)
        let other = fixture.makeViewModel(agentId: "another-agent")
        await other.load()
        #expect(other.store !== store)
        #expect(!other.agentNotFound)
    }
}
