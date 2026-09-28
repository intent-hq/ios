import Foundation
@testable import Intent
import Testing

extension ConversationWatchedAgentsTests {
    @Test func selfContainedEventsUpdateUnknownRowsWithoutDiscoveringThem() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:created", "workspaceId": "other-workspace",
            "data": ["agentId": "child", "agentName": "Delegate", "status": "responding"]
        ])
        #expect(watched.row("child").hasSummary)
        #expect(watched.row("child").workspaceId == "other-workspace")
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:stream:activity", "workspaceId": "other-workspace",
            "data": ["agentId": "child", "lastAgentResponse": "Building", "digest": "Fresh preview"]
        ])
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:renamed", "workspaceId": "other-workspace", "data": ["agentId": "child", "name": "Renamed"]
        ])
        #expect(watched.row("child").agent.name == "Renamed")
        #expect(watched.row("child").agent.displayMessage == "Fresh preview")
        watched.setVisible("child", visible: true, consumer: UUID())
        try await expectNever("discovery for event-projected rows") { !fixture.connection.traffic(since: checkpoint).requests.isEmpty }
        #expect(fixture.details.cached(agentId: "child") == nil)
    }

    @Test func newEventsSurviveOldDetailAndOldSubscriptionStatuses() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        fixture.connection.pendingMethods = ["agent.get", "agent.getSubscriptions"]
        watched.setVisible("child", visible: true, consumer: UUID())
        try await fixture.connection.waitForPendingRequests("agent.get")
        let refresh = Task { await model.store.fetchSubscriptions(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId) }
        defer { refresh.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.getSubscriptions")
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "data": ["agentId": "child", "name": "Latest", "status": "completed"]
        ])
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent("child")])
        fixture.connection.resolvePending("agent.getSubscriptions", with: fixture.subscriptions())
        await refresh.value
        try await waitUntil("newer row status retained") { watched.row("child").hasSummary }
        #expect(watched.row("child").agent.name == "Latest")
        #expect(watched.row("child").agent.status == "completed")
        #expect(!watched.row("child").agent.isActive)
    }

    @Test func wrongWorkspaceEventDoesNotPoisonChildAuthority() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        fixture.connection.pendingMethods = ["agent.get"]
        let watched = model.store.watchedAgentCoordinator
        watched.setVisible("child", visible: true, consumer: UUID())
        try await fixture.connection.waitForPendingRequests("agent.get")
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:stream:activity", "workspaceId": "wrong", "data": ["agentId": "child", "digest": "Wrong preview"]
        ])
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent("child")])
        try await waitUntil("authoritative child identity") { watched.row("child").hasSummary }
        #expect(watched.row("child").workspaceId == ConversationStartupFixture.workspaceId)
        #expect(watched.row("child").agent.digest == nil)
        fixture.connection.deliverEvent(method: "event", params: [
            "type": "agent:deleted", "workspaceId": "wrong", "data": ["agentId": "child"]
        ])
        #expect(!watched.row("child").isDeleted)
    }

    @Test func summaryArrivingWhileQueuedRemovesOnlyTheWatchedInterest() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = (0..<5).map { "child-\($0)" }
        let model = fixture.makeViewModel()
        await model.load()
        fixture.connection.pendingMethods = ["agent.get"]
        let watched = model.store.watchedAgentCoordinator
        for id in fixture.watchedIds { watched.setVisible(id, visible: true, consumer: UUID()) }
        try await fixture.connection.waitForPendingRequests("agent.get", count: 4)
        fixture.session.agentSummaries.seed([fixture.agent("child-4")], since: fixture.session.agentSummaries.beginRead())
        fixture.connection.pendingMethods = []
        for request in fixture.connection.traffic().calls("agent.get").filter({ $0.completed == nil }) {
            let id = try #require(request.params["agentId"] as? String)
            fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(id)])
        }
        try await expectNever("queued read after its summary arrived") {
            fixture.connection.traffic().calls("agent.get").contains { $0.params["agentId"] as? String == "child-4" }
        }
        #expect(watched.row("child-4").hasSummary)
        #expect(fixture.details.cached(agentId: "child-4") == nil)
    }

    @Test func deletionKeepsGroupMembershipAndNeverRequestsDeletedDetails() async {
        let connection = RPCRecordingConnection()
        connection.responseMap["agent.getSubscriptions"] = [
            "delegationGroups": [["expectedAgentIds": ["child", "gone"], "completedAgentIds": [], "deletedAgentIds": ["gone"]]],
            "agentStatuses": [:]
        ]
        let commands = ConversationCommands(connectionManager: connection)
        let watched = ConversationWatchedAgents(commands: commands)
        await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace")
        watched.setVisible("gone", visible: true, consumer: UUID())
        #expect(await watched.selectedAgent("gone") == nil)
        connection.deliverEvent(method: "event", params: ["type": "agent:deleted", "data": ["agentId": "child"]])
        #expect(watched.watchedAgentIds == ["child", "gone"])
        #expect(watched.row("child").isDeleted)
        #expect(await watched.selectedAgent("child") == nil)
        #expect(connection.traffic().calls("agent.get").isEmpty)
    }
}
