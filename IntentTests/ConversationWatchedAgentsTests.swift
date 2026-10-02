import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationWatchedAgentsTests {
    @Test func offscreenChildrenDoNotLoadOnSubscriptionOrActivity() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = (0..<30).map { "child-\($0)" }
        let model = fixture.makeViewModel()
        await model.load()
        model.store.handleStreamEvent("event", params: [
            "type": "agent:stream:activity", "data": ["agentId": "child-29"]
        ])
        try await expectNever("offscreen child discovery") {
            fixture.connection.traffic().calls("agent.get").count > 1
        }
        let traffic = fixture.connection.traffic()
        #expect(traffic.calls("agent.list").isEmpty)
        #expect(traffic.calls("agent.get").count == 1)
        #expect(model.store.watchedAgentIds.count == 30)
    }
}

extension ConversationWatchedAgentsTests {
    @Test func decoderKeepsGroupsStatusesAndUnknownMembers() async {
        let connection = RPCRecordingConnection()
        connection.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [["actorIds": ["live"]], ["filter": ["actorIds": ["legacy"]]]],
            "delegationGroups": [
                [
                "groupId": "group", "expectedAgentIds": ["live", "done", "gone", "unknown"],
                "completedAgentIds": ["done"], "deletedAgentIds": ["gone"]
                ]
            ],
            "agentStatuses": ["live": "responding", "done": "completed", "parent": "waiting", "unknown": NSNull()]
        ]
        let commands = ConversationCommands(connectionManager: connection)
        let watched = ConversationWatchedAgents(commands: commands)
        await watched.fetchSubscriptions(agentId: "parent", workspaceId: "parent-workspace")
        #expect(watched.watchedAgentIds == ["done", "gone", "legacy", "live", "unknown"])
        #expect(watched.groups.first?.id == "group")
        #expect(watched.delegationGroupStatus?.completed == 2)
        #expect(watched.delegationGroupStatus?.total == 4)
        #expect(watched.row("unknown").statusText == "Status unknown")
        #expect(!watched.row("unknown").isCompleted)
        #expect(watched.row("gone").isDeleted)
        #expect(watched.row("done").isCompleted)
        #expect(watched.row("live").agent.status == "responding")
        #expect(!watched.row("live").hasSummary)
        #expect(await watched.selectedAgent("gone") == nil)
        #expect(commands.agentDetails.summaries.cached(agentId: "parent").isEmpty)
        #expect(connection.traffic().methodCounts == ["agent.getSubscriptions": 1])
    }

    @Test func workspaceListProjectionPopulatesSummaryWithoutDetailAuthority() throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let workspace = try #require(WorkspaceStore.parseWorkspace([
            "id": "workspace", "title": "Workspace",
            "agentSummary": [
                "agents": [
                    ["id": "child", "name": "From workspace", "status": "waiting", "specialist": "implementor"]
                ]
            ]
        ]))
        fixture.session.workspaceStore.publishFetchedWorkspaces([workspace])
        let watched = fixture.makeViewModel().store.watchedAgentCoordinator
        watched.watchedAgentIds = ["child"]
        #expect(watched.row("child").agent.name == "From workspace")
        #expect(watched.row("child").workspaceId == "workspace")
        #expect(watched.row("child").agent.specialist == "implementor")
        #expect(fixture.details.cached(agentId: "child") == nil)
        #expect(fixture.connection.traffic().requests.isEmpty)
    }

    @Test func cachedWorkspaceAndAssistantSummariesNeedNoChildDetails() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = [ConversationStartupFixture.childId]
        let agents = AgentStore(connectionManager: fixture.connection, summaries: fixture.session.agentSummaries)
        await agents.fetchAgents(workspaceId: ConversationStartupFixture.workspaceId)
        let checkpoint = fixture.connection.checkpoint
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        watched.setVisible(ConversationStartupFixture.childId, visible: true, consumer: UUID())
        try await expectNever("detail for a cached workspace row") { fixture.connection.traffic(since: checkpoint).calls("agent.get").count > 1 }
        #expect(watched.row(ConversationStartupFixture.childId).agent.name == "Agent watched-child")
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.childId) == nil)
        // A summary cannot satisfy a richer route/parent/proposal detail request.
        _ = try await fixture.details.load(agentId: ConversationStartupFixture.childId)
        #expect(fixture.connection.traffic(since: checkpoint).calls("agent.get").count == 2)

        let assistantConnection = RPCRecordingConnection()
        let details = AgentDetailStore(connection: assistantConnection)
        assistantConnection.responseMap["agent.list"] = ["agents": [["id": "assistant", "name": "Assistant", "status": "idle"]]]
        let assistant = AssistantStore(connection: assistantConnection, summaries: details.summaries)
        await assistant.refresh()
        #expect(details.summaries.cached(agentId: "assistant")["workspaceId"] as? String == Workspace.chiefWorkspaceId)
        #expect(details.cached(agentId: "assistant") == nil)
        #expect(assistantConnection.traffic().methodCounts == ["agent.list": 1])
    }

    @Test func visibleAndSelectedReadsAreIndependentOfWorkspaceSizeIncludingCleanup() async throws {
        var totals: [RPCTraffic] = []
        for size in [10, 10_000] {
            let fixture = ConversationStartupFixture()
            fixture.watchedIds = ["child-0", "child-1", "child-2"]
            fixture.unrelatedAgentCount = size
            let model = fixture.makeViewModel()
            await model.load()
            let watched = model.store.watchedAgentCoordinator
            let consumer = UUID()
            watched.setVisible("child-0", visible: true, consumer: consumer)
            try await waitUntil("visible child") { watched.row("child-0").hasSummary }
            watched.setVisible("child-0", visible: false, consumer: consumer)
            watched.setVisible("child-1", visible: true, consumer: consumer)
            try await waitUntil("scrolled child") { watched.row("child-1").hasSummary }
            let selected = await watched.selectedAgent("child-2")
            #expect(selected?.workspaceId == ConversationStartupFixture.workspaceId)
            // Route handoff consumes the already-read detail, without a second read.
            _ = try await fixture.details.load(agentId: "child-2", workspaceId: selected?.workspaceId)
            watched.releaseVisibility(consumer: consumer)
            fixture.stop()
            try await waitUntil("all cleanup is recorded") {
                let traffic = fixture.connection.traffic()
                return traffic.calls("chat.unsubscribe").count == 1 && traffic.calls("events.unsubscribe").count == 2 && traffic.pendingCount == 0
            }
            let traffic = fixture.connection.traffic()
            print("Watched visible+selected+cleanup, unrelated \(size): \(traffic.summary)")
            #expect(traffic.methodCounts == [
                "chat.subscribe": 1, "agent.get": 4, "agent.getQueue": 1, "agent.getSubscriptions": 1,
                "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1, "chat.unsubscribe": 1, "events.unsubscribe": 2
            ])
            #expect(traffic.failures.isEmpty)
            totals.append(traffic)
        }
        #expect(totals[0].methodCounts == totals[1].methodCounts)
        #expect(totals[0].requestBytes == totals[1].requestBytes)
        #expect(totals[0].responseBytes == totals[1].responseBytes)
        #expect(totals[0].notificationBytes == totals[1].notificationBytes)
    }

    @Test func twoWindowsReuseVisibleRowsAndKeepRemainingInterest() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        await first.load()
        await second.load()
        #expect(first.store === second.store)
        let watched = first.store.watchedAgentCoordinator
        let firstWindow = UUID()
        let secondWindow = UUID()
        fixture.connection.pendingMethods = ["agent.get"]
        watched.setVisible("child", visible: true, consumer: firstWindow)
        watched.setVisible("child", visible: true, consumer: secondWindow)
        try await fixture.connection.waitForPendingRequests("agent.get")
        watched.releaseVisibility(consumer: firstWindow)
        first.teardownLiveStores()
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent("child")])
        try await waitUntil("second window row") { watched.row("child").hasSummary }
        watched.releaseVisibility(consumer: secondWindow)
        watched.setVisible("child", visible: true, consumer: firstWindow)
        try await expectNever("warm detail refetch") { fixture.connection.traffic().calls("agent.get").count > 2 }
        #expect(fixture.connection.traffic().calls("agent.list").isEmpty)
        #expect(fixture.connection.traffic().calls("chat.subscribe").count == 1)
    }
}

extension ConversationWatchedAgentsTests {
    @Test func bundledRowsAvoidDisplayDetailsButNeverSatisfyRouteDetails() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        fixture.bundlesWatchedAgents = true
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        #expect(watched.row("child").hasSummary)
        watched.setVisible("child", visible: true, consumer: UUID())
        #expect(await watched.selectedAgent("child")?.workspaceId == ConversationStartupFixture.workspaceId)
        try await expectNever("bundled display detail") { fixture.connection.traffic().calls("agent.get").count > 1 }
        #expect(fixture.details.cached(agentId: "child") == nil)
        #expect(fixture.connection.traffic().calls("agent.get").first?.params["agentId"] as? String == ConversationStartupFixture.parentId)
        _ = try await fixture.details.load(agentId: "child")
        #expect(fixture.connection.traffic().calls("agent.get").count == 2)
        #expect(fixture.details.cached(agentId: "child") != nil)
    }

    @Test(arguments: [false, true])
    func absentOrEmptyBundleRetainsVisibleFallback(empty: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        var response = fixture.subscriptions()
        if empty { response["agents"] = [] as [[String: Any]] }
        fixture.connection.responseForRequest = { method, _ in method == "agent.getSubscriptions" ? response : nil }
        fixture.connection.responseMap["agent.get"] = ["agent": fixture.agent("child")]
        let commands = ConversationCommands(connectionManager: fixture.connection)
        let watched = ConversationWatchedAgents(commands: commands)
        await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace")
        #expect(!watched.row("child").hasSummary)
        watched.setVisible("child", visible: true, consumer: UUID())
        try await waitUntil("legacy visible fallback") { watched.row("child").hasSummary }
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)
    }

    @Test func partialBundlePreservesMembershipAndCanonicalCrossWorkspaceIdentity() async {
        let connection = RPCRecordingConnection()
        let commands = ConversationCommands(connectionManager: connection)
        let watched = ConversationWatchedAgents(commands: commands)
        connection.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [["actorIds": ["child", "partial", "missing", "no-id"]]],
            "delegationGroups": [["expectedAgentIds": ["group-only", "gone"], "deletedAgentIds": ["gone"]]],
            "agents": [
                ["id": "child", "name": "Across workspaces", "workspaceId": "canonical"],
                ["id": "group-only", "name": "Group member", "workspaceId": "another"],
                ["id": "partial", "name": "No workspace"],
                ["id": "gone", "name": "Deleted member", "workspaceId": "canonical"],
                ["id": "unrelated", "name": "Ignore", "workspaceId": "canonical"],
                ["name": "Missing id", "workspaceId": "canonical"],
                ["id": "", "name": "Empty id", "workspaceId": "canonical"]
            ]
        ]
        await watched.fetchSubscriptions(agentId: "chief", workspaceId: Workspace.chiefWorkspaceId)
        #expect(watched.watchedAgentIds == ["child", "gone", "group-only", "missing", "no-id", "partial"])
        #expect(await watched.selectedAgent("child")?.workspaceId == "canonical")
        #expect(watched.row("group-only").hasSummary)
        #expect(!watched.row("partial").hasSummary)
        #expect(watched.row("partial").workspaceId == nil)
        #expect(!watched.row("missing").hasSummary)
        #expect(commands.agentDetails.summaries.cached(agentId: "unrelated").isEmpty)
        #expect(commands.agentDetails.summaries.cached(agentId: "").isEmpty)
        watched.setVisible("gone", visible: true, consumer: UUID())
        #expect(await watched.selectedAgent("gone") == nil)
        #expect(connection.traffic().calls("agent.get").isEmpty)
        connection.responseMap["agent.get"] = ["agent": ["id": "partial", "name": "Resolved", "workspaceId": "resolved"]]
        #expect(await watched.selectedAgent("partial")?.workspaceId == "resolved")
        #expect(connection.traffic().calls("agent.get").count == 1)
    }

    @Test func bundledSummariesStayWithinTheirBackend() async {
        let first = ConversationCommands(connectionManager: RPCRecordingConnection())
        let secondConnection = RPCRecordingConnection()
        let second = ConversationCommands(connectionManager: secondConnection)
        secondConnection.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [["actorIds": ["same-id"]]],
            "agents": [["id": "same-id", "name": "Second backend", "workspaceId": "workspace"]]
        ]
        let watched = ConversationWatchedAgents(commands: second)
        await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace")
        #expect(watched.row("same-id").hasSummary)
        #expect(first.agentDetails.summaries.cached(agentId: "same-id").isEmpty)
        #expect(second.agentDetails.cached(agentId: "same-id") == nil)
    }
}
