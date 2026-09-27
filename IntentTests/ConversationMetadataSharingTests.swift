import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationMetadataSharingTests {
    @Test func delayedInitialReadCannotRaiseStreamingAfterIdleSnapshot() async throws {
        let fixture = ConversationStartupFixture()
        let viewModel = fixture.makeViewModel()
        fixture.connection.pendingMethods = ["agent.get"]
        let load = Task { await viewModel.load() }
        defer { load.cancel(); fixture.stop() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        try await waitUntil("initial chat snapshot") { !viewModel.isLoading }
        var oldAgent = fixture.agent(ConversationStartupFixture.parentId)
        oldAgent["turnInFlight"] = true
        fixture.connection.resolvePending("agent.get", with: ["agent": oldAgent])
        await load.value
        #expect(!viewModel.isStreaming)
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)
    }

    @Test func markerEventAndConditionalViewTaskKeepProposalMountsInOpeningBudget() async throws {
        let fixture = ConversationStartupFixture()
        let viewModel = fixture.makeViewModel()
        let proposals = fixture.makeProposalStore()
        fixture.connection.pendingMethods = ["agent.get"]
        let load = Task { await viewModel.load() }
        defer { load.cancel(); fixture.stop() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        fixture.connection.deliverEvent(method: "events.event", params: [
            "event": [
                "type": "agent:updated", "data": [
                    "agentId": ConversationStartupFixture.parentId,
                    "lastSeenMessageId": "new-seen", "pendingQuestionsMessageId": "",
                    "dismissedQuestionsMessageId": "new-dismissed",
                    "pendingProposals": [], "proposalResolutions": ["proposal-1": "applied"]
                ]
            ]
        ])
        try await waitUntil("new marker event") { viewModel.store.lastSeenMessageId == "new-seen" }
        // ConversationView's conditional metadata-generation task starts while
        // cards mount. All three consumers must join the same detail flight.
        let block = ContentBlock(type: .resource, resource: .init(
            uri: nil, mimeType: "application/vnd.intent.proposal+json", text: """
            {"kind":"bulk-op","payload":{"operation":"workspace.bulkArchive","ids":["alpha"]},
             "preview":{"title":"Archive"},"applyToolCallId":"proposal-1"}
            """
        ))
        #expect(ActionProposal.parse(block) != nil)
        let messages = [ConversationMessage(id: "old-message", role: .assistant, contentBlocks: [block])]
        let viewRefresh = Task { await proposals.loadIfPresent(in: messages) }
        let cardMount = Task { await proposals.loadIfNeeded() }
        defer { viewRefresh.cancel(); cardMount.cancel() }
        var oldAgent = fixture.agent(ConversationStartupFixture.parentId)
        oldAgent["metadata"] = [
            "lastSeenMessageId": "old-seen", "pendingQuestionsMessageId": "old-question",
            "pendingProposals": [["proposalId": "proposal-1", "messageId": "old-message"]]
        ]
        fixture.connection.resolvePending("agent.get", with: ["agent": oldAgent])
        await load.value
        await viewRefresh.value
        await cardMount.value
        await proposals.loadIfNeeded() // A later card after the first read settled.
        #expect(viewModel.store.lastSeenMessageId == "new-seen")
        #expect(viewModel.store.pendingQuestionsMessageId?.isEmpty == true)
        #expect(viewModel.store.dismissedQuestionsMessageId == "new-dismissed")
        #expect(proposals.pending.isEmpty)
        #expect(proposals.resolutions["proposal-1"] == "applied")
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)
        #expect(fixture.connection.traffic().requests.count == 9)
        #expect(fixture.connection.traffic().pendingCount == 0)
    }

    @Test func viewTaskWithoutProposalContentDoesNotReadDetail() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let messages = [ConversationMessage(id: "plain-message", role: .assistant, contentBlocks: [ContentBlock(type: .text, text: "Plain")])]
        await fixture.makeProposalStore().loadIfPresent(in: messages)
        #expect(fixture.connection.traffic().requests.isEmpty)
    }

    @Test func restoredRouteValidationHandsDetailToConversation() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let coordinator = AppCoordinator(workspaceStore: WorkspaceStore(forTesting: true), connection: fixture.connection)
        coordinator.agentDetails = fixture.details
        await coordinator.validateRestoredAgent(
            agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId
        )
        await fixture.makeViewModel().load()
        await fixture.makeProposalStore().loadIfNeeded()
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)
        #expect(fixture.connection.traffic().requests.count == 9)
    }

    @Test func lateReadCannotUndoLocalSeenOrDismissal() async throws {
        let connection = FakeConnectionManager()
        let details = AgentDetailStore(connection: connection)
        let store = ConversationStore(connectionManager: connection, agentDetails: details)
        store.bindAgent("parent")
        store.messages = [ConversationMessage(id: "new-seen", role: .assistant)]
        connection.pendingMethods = ["agent.get"]
        connection.responseMap["agent.markSeen"] = ["lastSeenMessageId": "new-seen"]
        connection.responseMap["agent.dismissQuestions"] = ["dismissedQuestionsMessageId": "new-dismissed"]
        let read = Task { await store.fetchAgentStreamingState(agentId: "parent") }
        defer { read.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        await store.markSeen(agentId: "parent", workspaceId: "workspace")
        try await store.dismissQuestions(agentId: "parent", messageId: "new-dismissed", workspaceId: "workspace")
        connection.resolvePending("agent.get", with: [
            "agent": [
                "id": "parent", "metadata": [
                    "lastSeenMessageId": "old-seen", "dismissedQuestionsMessageId": "old-dismissed"
                ]
            ]
        ])
        await read.value
        #expect(store.lastSeenMessageId == "new-seen")
        #expect(store.dismissedQuestionsMessageId == "new-dismissed")
        #expect(details.cached(agentId: "parent")?.metadata["lastSeenMessageId"] as? String == "new-seen")
    }

    @Test func coldTitleFallbackIsSharedAndCounted() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let workspaces = WorkspaceStore(connectionManager: fixture.connection)
        fixture.connection.pendingMethods = ["workspace.list"]
        let firstTitle = Task { await workspaces.fetchIfNeeded() }
        let secondTitle = Task { await workspaces.fetchIfNeeded() }
        defer { firstTitle.cancel(); secondTitle.cancel() }
        try await fixture.connection.waitForPendingRequests("workspace.list")
        await fixture.makeViewModel().load()
        fixture.connection.resolvePending("workspace.list", with: ["workspaces": []])
        await firstTitle.value
        await secondTitle.value
        await workspaces.fetchIfNeeded() // Successful empty lists are warm too.
        #expect(fixture.connection.traffic().calls("workspace.list").count == 1)
        #expect(fixture.connection.traffic().requests.count == 10)
        #expect(fixture.connection.traffic().pendingCount == 0)
    }

    @Test func failedOpeningReadsStayInTotalsAndLateCardCanRetry() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.connection.errorMap["agent.get"] = NSError(domain: "Test", code: 1)
        await fixture.makeViewModel().load()
        let failed = fixture.connection.traffic()
        #expect(!failed.calls("agent.get").isEmpty)
        #expect(failed.failures.count == failed.calls("agent.get").count)
        #expect(fixture.details.cached(agentId: ConversationStartupFixture.parentId) == nil)
        fixture.connection.errorMap.removeValue(forKey: "agent.get")
        fixture.parentMetadata["pendingProposals"] = [["proposalId": "proposal", "messageId": "message"]]
        let card = fixture.makeProposalStore()
        await card.loadIfNeeded()
        let settled = fixture.connection.traffic()
        #expect(settled.calls("agent.get").count == failed.calls("agent.get").count + 1)
        #expect(settled.requests.count == failed.requests.count + 1)
        #expect(settled.pendingCount == 0)
        #expect(card.pending["proposal"] == "message")
        #expect(card.loadError == nil)
        print("Opening failure and late proposal retry: \(settled.summary)")
    }

    @Test func failedTitleLookupRetriesAndExplicitRefreshStillReads() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let workspaces = WorkspaceStore(connectionManager: fixture.connection)
        fixture.connection.errorMap["workspace.list"] = NSError(domain: "Test", code: 1)
        await workspaces.fetchIfNeeded()
        #expect(workspaces.lastUpdated == nil)
        #expect(!workspaces.isLoading)
        #expect(fixture.connection.traffic().calls("workspace.list").count == 1)
        #expect(fixture.connection.traffic().failures.count == 1)

        fixture.connection.errorMap.removeValue(forKey: "workspace.list")
        fixture.connection.responseMap["workspace.list"] = ["workspaces": []]
        await workspaces.fetchIfNeeded()
        #expect(workspaces.lastUpdated != nil)
        #expect(!workspaces.isLoading)
        #expect(fixture.connection.traffic().calls("workspace.list").count == 2)
        await workspaces.fetchIfNeeded()
        #expect(fixture.connection.traffic().calls("workspace.list").count == 2)

        await workspaces.fetchAll()
        let traffic = fixture.connection.traffic()
        #expect(traffic.calls("workspace.list").count == 3)
        #expect(traffic.requests.count == 3)
        #expect(traffic.failures.count == 1)
        #expect(traffic.pendingCount == 0)
    }
}
