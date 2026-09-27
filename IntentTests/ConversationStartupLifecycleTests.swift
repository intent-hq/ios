import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupLifecycleTests {
    @Test func transcriptStartsBeforeAnySideReply() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let model = fixture.makeViewModel()
        connection.pendingMethods = ["events.subscribe", "agent.getQueue", "agent.get", "agent.getSubscriptions"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("events.subscribe")
        try await waitUntil("snapshot while every side reply is held") {
            !model.isLoading && !model.messages.isEmpty
        }
        #expect(connection.paramsForMethod("chat.subscribe").count == 1)
        try await connection.waitForPendingRequests("agent.get")
        try await connection.waitForPendingRequests("agent.getQueue")
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        #expect(connection.pendingRequestCount("agent.get") == 1)
        #expect(connection.pendingRequestCount("agent.getQueue") == 1)
        #expect(connection.pendingRequestCount("agent.getSubscriptions") == 1)
        #expect(!model.hasLatchedNewMessagesDividerAnchor)
        #expect(model.newMessagesDividerAnchorId == nil)
        #expect(!connection.didCallMethod("agent.getConversation"))
        #expect(!connection.didCallMethod("agent.getMessageBlock"))
    }

    @Test(arguments: ["before", "during", "after"])
    func initialReplayAndRepeatedLoadsHaveOneBootstrap(placement: String) async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let model = fixture.makeViewModel()
        defer { fixture.stop() }
        if placement == "before" { try await fixture.deliverInitialConnectionBeforeBinding() }
        connection.pendingMethods = ["agent.getQueue"]
        let first = Task { await model.load() }
        defer { first.cancel() }
        try await connection.waitForPendingRequests("agent.getQueue")
        if placement == "during" { connection.releaseConnectionStateDelivery() }
        let second = Task { await model.load() }
        defer { second.cancel() }
        model.conversationAppeared()
        model.conversationAppeared()
        connection.pendingMethods.remove("agent.getQueue")
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        await first.value
        await second.value
        if placement == "after" { connection.releaseConnectionStateDelivery() }
        connection.simulateConnect()
        try await expectNever("duplicate initial chat registration") {
            connection.paramsForMethod("chat.subscribe").count != 1
        }
        await model.load()
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
        #expect(connection.paramsForMethod("agent.getSubscriptions").count == 1)
        #expect(connection.paramsForMethod("agent.get").count == 1)
    }

    @Test func queueEventWinsOverAnOlderSeed() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.getQueue"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getQueue")
        connection.deliverEvent(method: "event", params: [
            "type": "agent:queue:updated", "data": [
                "agentId": ConversationStartupFixture.parentId,
                "queue": [["id": "new-queue", "content": "New queued message", "queuedAt": "2026-09-27", "position": 0]]
            ]
        ])
        try await waitUntil("queue event applied") { model.store.queuedMessages.map(\.id) == ["new-queue"] }
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["new-queue"])
    }

    @Test func processingEventDuringQueueSeedKeepsTheRemainingQueue() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let model = fixture.makeViewModel()
        connection.pendingMethods = ["agent.getQueue"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getQueue")
        connection.deliverEvent(method: "event", params: [
            "type": "agent:queue:processing",
            "data": ["agentId": ConversationStartupFixture.parentId, "messageId": "processed"]
        ])
        let remaining: [String: Any] = ["id": "remaining", "content": "Next", "queuedAt": "2026-09-27", "position": 1]
        let processed: [String: Any] = ["id": "processed", "content": "Now", "queuedAt": "2026-09-27", "position": 0]
        connection.resolvePending("agent.getQueue", with: ["queue": [processed, remaining]])
        try await connection.waitForPendingRequests("agent.getQueue")
        connection.resolvePending("agent.getQueue", with: ["queue": [remaining]])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["remaining"])
        #expect(connection.paramsForMethod("agent.getQueue").count == 2)
    }
}
