import Foundation
@testable import Intent
import Testing

private struct WatchedSummaryContext {
    let connection: RPCRecordingConnection
    let commands: ConversationCommands
    let watched: ConversationWatchedAgents
}

extension ConversationWatchedAgentsTests {
    private func summaryContext() -> WatchedSummaryContext {
        let connection = RPCRecordingConnection()
        let commands = ConversationCommands(connectionManager: connection)
        let watched = ConversationWatchedAgents(commands: commands)
        watched.watchedAgentIds = ["child"]
        return WatchedSummaryContext(connection: connection, commands: commands, watched: watched)
    }

    @Test func authoritativeSubscriptionIdleRetiresStaleLiveness() async {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        summaries.seed([
            [
                "id": "child", "workspaceId": "workspace", "name": "Child", "status": "responding",
                "isStreaming": true, "isResponding": true
            ]
        ], since: summaries.beginRead())
        connection.responseMap["agent.getSubscriptions"] = ["subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "idle"]]
        await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace")
        #expect(watched.row("child").agent.status == "idle")
        #expect(!watched.row("child").agent.isActive)
        #expect(watched.row("child").statusText == "Idle")
    }

    @Test(arguments: [false, true])
    func attentionClearRetiresBothProjectionSurfaces(nested: Bool) {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        var row: [String: Any] = ["id": "child", "workspaceId": "workspace", "name": "Child", "status": "idle"]
        let attention: [String: Any] = ["attentionRequestKind": "blocker", "attentionRequestReason": "Waiting", "attentionRequestTimestamp": "2026-09-28T01:00:00Z"]
        if nested { row["metadata"] = attention } else { row.merge(attention) { _, value in value } }
        summaries.seed([row], since: summaries.beginRead())
        #expect(watched.row("child").agent.pendingAttentionRequest != nil)
        connection.deliverEvent(method: "event", params: ["type": "agent:updated", "workspaceId": "workspace", "data": ["agentId": "child", "attentionRequestCleared": true]])
        #expect(watched.row("child").agent.pendingAttentionRequest == nil)
        #expect(connection.traffic().requests.isEmpty)
    }

    @Test func partialWorkspaceSummaryPreservesKnownMetadata() throws {
        let context = summaryContext()
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        summaries.seed([
            [
                "id": "child", "workspaceId": "workspace", "name": "Child", "status": "idle",
                "metadata": ["specialist": "implementor", "attentionRequestKind": "blocker", "attentionRequestReason": "Waiting"]
            ]
        ], since: summaries.beginRead())
        let workspace = try #require(WorkspaceStore.parseWorkspace([
            "id": "workspace", "title": "Workspace",
            "agentSummary": ["agents": [["id": "child", "name": "Child", "status": "idle", "specialist": "implementor"]]]
        ]))
        summaries.seedWorkspaces([workspace], since: summaries.beginRead())
        #expect(watched.row("child").agent.pendingAttentionRequest?.reason == "Waiting")
        #expect(watched.row("child").agent.specialist == "implementor")
    }

    @Test func flatSpecialistEventUpdatesCachedAvatar() {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        summaries.seed([["id": "child", "workspaceId": "workspace", "name": "Child", "metadata": ["specialist": "implementor"]]], since: summaries.beginRead())
        connection.deliverEvent(method: "event", params: ["type": "agent:updated", "workspaceId": "workspace", "data": ["agentId": "child", "specialist": "verifier"]])
        #expect(watched.row("child").agent.specialist == "verifier")
        #expect(connection.traffic().requests.isEmpty)
    }

    @Test func olderListResponseCannotUndoNewerSuccessfulDetail() async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let agents = AgentStore(connectionManager: connection, summaries: commands.agentDetails.summaries)
        connection.pendingMethods = ["agent.list", "agent.get"]
        let oldList = Task { await agents.fetchAgents(workspaceId: "workspace") }
        defer { oldList.cancel() }
        try await connection.waitForPendingRequests("agent.list")
        let detail = Task { try await commands.agentDetails.load(agentId: "child") }
        defer { detail.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        connection.resolvePending("agent.get", with: ["agent": ["id": "child", "workspaceId": "workspace", "name": "New name", "status": "completed"]])
        _ = try await detail.value
        #expect(watched.row("child").agent.name == "New name")
        connection.resolvePending("agent.list", with: ["agents": [["id": "child", "name": "Old name", "status": "responding"]]])
        await oldList.value
        #expect(watched.row("child").agent.name == "New name")
        #expect(watched.row("child").agent.status == "completed")
        #expect(commands.agentDetails.cached(agentId: "child")?.values["name"] as? String == "New name")
    }

    @Test func sameActorTurnVisibilityReplacementKeepsLiveInterest() async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        connection.pendingMethods = ["agent.get"]
        let consumer = UUID()
        watched.setVisible("child", visible: true, consumer: consumer)
        try await connection.waitForPendingRequests("agent.get")
        watched.releaseVisibility(consumer: consumer)
        watched.setVisible("child", visible: true, consumer: consumer)
        for _ in 0..<30 { await Task.yield() }
        connection.pendingMethods = []
        connection.responseMap["agent.get"] = ["agent": ["id": "child", "workspaceId": "workspace", "name": "Child"]]
        // The old wire operation may outlive its cancelled final interest. A
        // replacement generation, when needed, is also part of the ledger.
        let pending = connection.traffic().calls("agent.get").filter { $0.completed == nil }
        #expect(pending.count <= 2)
        for _ in pending {
            connection.resolvePending("agent.get", with: try #require(connection.responseMap["agent.get"]))
        }
        try await waitUntil("replacement visibility loads") { watched.row("child").hasSummary }
        #expect(watched.errors["child"] == nil)
        #expect(commands.agentDetails.cached(agentId: "child") != nil)
        watched.releaseVisibility(consumer: consumer)
    }

    @Test func selfContainedEventIdentityRejectsConflictingWorkspaceEvent() {
        let context = summaryContext()
        let connection = context.connection
        let watched = context.watched
        connection.deliverEvent(method: "event", params: ["type": "agent:created", "workspaceId": "canonical", "data": ["agentId": "child", "agentName": "Child", "status": "responding"]])
        #expect(watched.row("child").hasSummary)
        #expect(watched.row("child").workspaceId == "canonical")
        connection.deliverEvent(method: "event", params: ["type": "agent:deleted", "workspaceId": "unrelated", "data": ["agentId": "child"]])
        #expect(watched.row("child").workspaceId == "canonical")
        #expect(!watched.row("child").isDeleted)
    }

    @Test func statusReadCannotImportWorkspaceFromUnrelatedActivityPatch() async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        summaries.seed([["id": "child", "workspaceId": "canonical", "name": "Child", "status": "responding"]], since: summaries.beginRead())
        connection.pendingMethods = ["agent.getSubscriptions"]
        let subscriptions = Task { await watched.fetchSubscriptions(agentId: "parent", workspaceId: "parent-workspace") }
        defer { subscriptions.cancel() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        connection.deliverEvent(method: "event", params: ["type": "agent:idle", "workspaceId": "canonical", "data": ["agentId": "child", "agentName": "Newest"]])
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "responding"]])
        await subscriptions.value
        #expect(watched.row("child").agent.name == "Newest")
        #expect(watched.row("child").agent.status == "idle")
        #expect(watched.row("child").workspaceId == "canonical")
    }
}

extension ConversationWatchedAgentsTests {
    @Test func newerStatusOnlyReadFillsLivenessWhileOlderDetailFillsName() async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        connection.pendingMethods = ["agent.get", "agent.getSubscriptions"]
        let detail = Task { try await commands.agentDetails.load(agentId: "child") }
        defer { detail.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        let status = Task { await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace") }
        defer { status.cancel() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "idle"]])
        await status.value
        connection.resolvePending("agent.get", with: [
            "agent": ["id": "child", "name": "From detail", "workspaceId": "child-workspace", "status": "responding", "isStreaming": true, "isResponding": true]
        ])
        _ = try await detail.value
        #expect(watched.row("child").hasSummary)
        #expect(watched.row("child").workspaceId == "child-workspace")
        #expect(watched.row("child").agent.name == "From detail")
        #expect(watched.row("child").statusText == "Idle")
        #expect(!watched.row("child").agent.isActive)
        #expect(connection.traffic().methodCounts == ["agent.get": 1, "agent.getSubscriptions": 1])
    }

    @Test(arguments: [false, true], [false, true])
    func summaryReadOrderPreservesOmittedFieldsAndFailedReads(listFirst: Bool, detailFails: Bool) async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let agents = AgentStore(connectionManager: connection, summaries: commands.agentDetails.summaries)
        connection.pendingMethods = ["agent.list", "agent.get"]
        let list = Task { await agents.fetchAgents(workspaceId: "workspace") }
        defer { list.cancel() }
        try await connection.waitForPendingRequests("agent.list")
        let detail = Task { try? await commands.agentDetails.load(agentId: "child") }
        defer { detail.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        let listReply: [String: Any] = [
            "agents": [
                [
                    "id": "child", "name": "Old name", "status": "responding", "digest": "Known preview",
                    "metadata": ["specialist": "implementor", "attentionRequestKind": "blocker", "attentionRequestReason": "Waiting"]
                ]
            ]
        ]
        if listFirst {
            connection.resolvePending("agent.list", with: listReply)
            await list.value
        }
        if detailFails {
            connection.failPending("agent.get", with: NSError(domain: "Test", code: 1))
        } else {
            connection.resolvePending("agent.get", with: [
                "agent": [
                    "id": "child", "workspaceId": "workspace", "name": "New name", "status": "completed",
                    "metadata": ["specialist": "verifier"]
                ]
            ])
        }
        _ = await detail.value
        if !listFirst { connection.resolvePending("agent.list", with: listReply) }
        await list.value
        let row = watched.row("child")
        #expect(row.agent.name == (detailFails ? "Old name" : "New name"))
        #expect(row.agent.status == (detailFails ? "responding" : "completed"))
        #expect(row.agent.specialist == (detailFails ? "implementor" : "verifier"))
        #expect(row.agent.pendingAttentionRequest?.reason == "Waiting")
        #expect(row.agent.displayMessage == "Known preview")
        #expect((commands.agentDetails.cached(agentId: "child") == nil) == detailFails)
        #expect(connection.traffic().methodCounts == ["agent.list": 1, "agent.get": 1])
        #expect(connection.traffic().pendingCount == 0)
    }

    @Test func newLiveEventSurvivesOlderTerminalStatusAndAttentionSnapshot() async throws {
        let context = summaryContext()
        let connection = context.connection
        let commands = context.commands
        let watched = context.watched
        let summaries = commands.agentDetails.summaries
        summaries.seed([
            [
                "id": "child", "workspaceId": "workspace", "name": "Child", "status": "idle",
                "metadata": ["attentionRequestKind": "blocker", "attentionRequestReason": "Old"]
            ]
        ], since: summaries.beginRead())
        connection.pendingMethods = ["agent.getSubscriptions", "agent.list"]
        let subscriptions = Task { await watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace") }
        let agents = AgentStore(connectionManager: connection, summaries: summaries)
        let list = Task { await agents.fetchAgents(workspaceId: "workspace") }
        defer { subscriptions.cancel(); list.cancel() }
        try await connection.waitForPendingRequests("agent.getSubscriptions")
        try await connection.waitForPendingRequests("agent.list")
        connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "workspaceId": "workspace",
            "data": ["agentId": "child", "status": "responding", "isStreaming": true, "isResponding": true, "attentionRequestCleared": true]
        ])
        connection.resolvePending("agent.getSubscriptions", with: ["subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "idle"]])
        connection.resolvePending("agent.list", with: [
            "agents": [
                [
                    "id": "child", "name": "Child", "metadata": ["attentionRequestKind": "blocker", "attentionRequestReason": "Old"]
                ]
            ]
        ])
        await subscriptions.value
        await list.value
        #expect(watched.row("child").agent.status == "responding")
        #expect(watched.row("child").agent.isStreaming)
        #expect(watched.row("child").agent.isResponding)
        #expect(watched.row("child").agent.pendingAttentionRequest == nil)
        connection.deliverEvent(method: "event", params: [
            "type": "agent:updated", "workspaceId": "workspace",
            "data": ["agentId": "child", "attentionRequestKind": "discussion", "attentionRequestReason": "New"]
        ])
        #expect(watched.row("child").agent.pendingAttentionRequest?.reason == "New")
        #expect(connection.traffic().methodCounts == ["agent.list": 1, "agent.getSubscriptions": 1])
        #expect(commands.agentDetails.cached(agentId: "child") == nil)
    }
}

extension ConversationWatchedAgentsTests {
    @Test func sparseBundlePreservesMetadataAndStatusMapRetiresLiveness() async {
        let context = summaryContext()
        let summaries = context.commands.agentDetails.summaries
        summaries.seed([
            [
                "id": "child", "workspaceId": "workspace", "name": "Old name", "digest": "Keep preview",
                "metadata": ["specialist": "implementor", "attentionRequestKind": "blocker", "attentionRequestReason": "Keep reason"]
            ]
        ], since: summaries.beginRead())
        context.connection.responseMap["agent.getSubscriptions"] = [
            "subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "idle"],
            "agents": [["id": "child", "workspaceId": "workspace", "name": "New name", "isStreaming": true, "metadata": ["specialist": "verifier"]]]
        ]
        await context.watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace")
        let row = context.watched.row("child")
        #expect(row.agent.name == "New name")
        #expect(row.agent.digest == "Keep preview")
        #expect(row.agent.specialist == "verifier")
        #expect(row.agent.pendingAttentionRequest?.reason == "Keep reason")
        #expect(row.agent.status == "idle")
        #expect(!row.agent.isStreaming)
        #expect(context.commands.agentDetails.cached(agentId: "child") == nil)
    }

    @Test(arguments: [false, true])
    func staleBundleCannotReplaceNewerEventOrDetail(detail: Bool) async throws {
        let context = summaryContext()
        context.connection.pendingMethods = ["agent.getSubscriptions"]
        let read = Task { await context.watched.fetchSubscriptions(agentId: "parent", workspaceId: "workspace") }
        defer { read.cancel() }
        try await context.connection.waitForPendingRequests("agent.getSubscriptions")
        if detail {
            context.connection.responseMap["agent.get"] = ["agent": ["id": "child", "workspaceId": "canonical", "name": "New name", "status": "completed"]]
            _ = try await context.commands.agentDetails.load(agentId: "child")
        } else {
            context.connection.deliverEvent(method: "event", params: [
                "type": "agent:updated", "workspaceId": "canonical",
                "data": ["agentId": "child", "agentName": "New name", "status": "completed"]
            ])
        }
        context.connection.resolvePending("agent.getSubscriptions", with: [
            "subscriptions": [["actorIds": ["child"]]], "agentStatuses": ["child": "responding"],
            "agents": [["id": "child", "workspaceId": "canonical", "name": "Old name", "status": "responding", "digest": "Fill omitted preview", "isStreaming": true]]
        ])
        await read.value
        let row = context.watched.row("child")
        #expect(row.agent.name == "New name")
        #expect(row.agent.status == "completed")
        #expect(!row.agent.isStreaming)
        #expect(row.agent.digest == "Fill omitted preview")
        #expect(row.workspaceId == "canonical")
    }
}
