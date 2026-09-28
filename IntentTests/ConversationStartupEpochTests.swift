import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupEpochTests {
    @Test func aCompleteQueueSnapshotStillWinsBetweenProcessingRemovals() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let model = fixture.makeViewModel()
        connection.pendingMethods = ["agent.getQueue"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getQueue")
        event("agent:queue:processing", connection: connection, fields: ["messageId": "old"])
        event("agent:queue:updated", connection: connection, fields: ["queue": [row("new"), row("fresh")]])
        event("agent:queue:processing", connection: connection, fields: ["messageId": "new"])
        connection.resolvePending("agent.getQueue", with: ["queue": [row("old"), row("stale")]])
        await load.value
        #expect(model.store.queuedMessages.map(\.id) == ["fresh"])
        #expect(connection.paramsForMethod("agent.getQueue").count == 1)
    }

    @Test func queuedEventsCannotReadAfterDisconnectButExplicitReadsAndReconnectSurvive() async throws {
        let fixture = ConversationStartupFixture()
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        let connection = fixture.connection
        defer { fixture.stop() }
        await first.load()
        await second.load()
        connection.releaseConnectionStateDelivery()
        let checkpoint = connection.checkpoint
        event("agent:queue:updated", connection: connection)
        event("agent:subscribed", connection: connection)
        event("agent:updated", connection: connection)
        connection.simulateDisconnect()
        try await expectNever("queued event reads after disconnect") { !connection.traffic(since: checkpoint).requests.isEmpty }
        await first.store.fetchQueue(agentId: ConversationStartupFixture.parentId)
        await first.store.fetchSubscriptions(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId)
        #expect(connection.traffic(since: checkpoint).calls("agent.getQueue").count == 1)
        #expect(connection.traffic(since: checkpoint).calls("agent.getSubscriptions").count == 1)
        let reconnect = connection.checkpoint
        connection.simulateConnect()
        connection.simulateConnect()
        try await waitUntil("one shared reconnect settles") {
            connection.traffic(since: reconnect).calls("chat.subscribe").count == 1
                && connection.traffic(since: reconnect).calls("agent.getSubscriptions").count == 1
                && connection.traffic(since: reconnect).pendingCount == 0
        }
        #expect(connection.traffic(since: reconnect).calls("agent.getQueue").count == 1)
        #expect(first.store === second.store)
    }

    @Test func processingDuringTrailingQueueReadFoldsWithoutAThirdRead() async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.getQueue"]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.getQueue")
        event("agent:queue:updated", connection: connection)
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        try await connection.waitForPendingRequests("agent.getQueue")
        event("agent:queue:processing", connection: connection, fields: ["messageId": "one"])
        event("agent:queue:processing", connection: connection, fields: ["messageId": "two"])
        connection.resolvePending("agent.getQueue", with: ["queue": [row("one"), row("two"), row("remaining")]])
        try await expectNever("third queue read") { connection.paramsForMethod("agent.getQueue").count > 2 }
        #expect(model.store.queuedMessages.map(\.id) == ["remaining"])
    }

    @Test(arguments: ["agent.getQueue", "agent.getSubscriptions"])
    func repeatedInvalidationsHaveOneTrailingRead(method: String) async throws {
        let fixture = ConversationStartupFixture()
        let model = fixture.makeViewModel()
        let connection = fixture.connection
        let type = method == "agent.getQueue" ? "agent:queue:updated" : "agent:subscribed"
        let seed: [String: Any] = method == "agent.getQueue" ? ["queue": []] : ["subscriptions": []]
        connection.pendingMethods = [method]
        let load = Task { await model.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests(method)
        event(type, connection: connection)
        connection.resolvePending(method, with: seed)
        try await connection.waitForPendingRequests(method)
        event(type, connection: connection)
        event(type, connection: connection)
        connection.resolvePending(method, with: seed)
        try await expectNever("unbounded seed reconciliation") { connection.paramsForMethod(method).count > 2 }
        try #require(connection.paramsForMethod(method).count == 2)
        await load.value
        let explicit = Task {
            if method == "agent.getQueue" { await model.store.fetchQueue(agentId: ConversationStartupFixture.parentId) } else {
                await model.store.fetchSubscriptions(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId)
            }
        }
        defer { explicit.cancel() }
        try await connection.waitForPendingRequests(method)
        connection.resolvePending(method, with: seed)
        await explicit.value
        #expect(connection.paramsForMethod(method).count == 3, "a later independent caller can reconcile again")
    }

    private func event(_ type: String, connection: RPCRecordingConnection, fields: [String: Any] = [:]) {
        connection.deliverEvent(method: "event", params: [
            "type": type, "data": fields.merging(["agentId": ConversationStartupFixture.parentId]) { _, value in value }
        ])
    }

    private func row(_ id: String) -> [String: Any] {
        ["id": id, "content": id, "queuedAt": "2026-09-27", "position": 0]
    }
}
