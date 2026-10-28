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
        try await waitUntil("buffered marker awaiting authority") { !viewModel.store.pendingWorkspaceEvents.isEmpty }
        #expect(viewModel.store.lastSeenMessageId != "new-seen")
        #expect(!viewModel.store.metadataReadyForEntry && !viewModel.isEntryScrollReady)
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
        #expect(fixture.connection.traffic().requests.count == 8)
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
        #expect(fixture.connection.traffic().requests.count == 8)
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
        #expect(fixture.connection.traffic().requests.count == 9)
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

extension ConversationMetadataSharingTests {
    private func dispatchMetadataRefresh(_ eventType: String, store: ConversationStore, fixture: ConversationStartupFixture) {
        // The session listener invalidates incomplete updates before the view
        // handles them. Dispatch synchronously to hold the view's queued task.
        if eventType == "agent:updated" { fixture.details.invalidate(agentId: ConversationStartupFixture.parentId) }
        var data = ["agentId": ConversationStartupFixture.parentId]
        if eventType == "agent:status-changed" { data["status"] = "idle" }
        store.handleStreamEvent("events.event", params: [
            "event": ["type": eventType, "data": data]
        ])
    }

    @Test(arguments: ["agent:updated", "agent:idle", "agent:status-changed"])
    func queuedViewMetadataRefreshEndsWithActivation(eventType: String) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)

        dispatchMetadataRefresh(eventType, store: viewModel.store, fixture: fixture)
        viewModel.teardownLiveStores()
        try await expectNever("a metadata read from the closed view") {
            fixture.connection.traffic().calls("agent.get").count > 1
        }

        // A valid, unleased restored-route read still seeds the next activation.
        _ = try await fixture.details.load(agentId: ConversationStartupFixture.parentId)
        await viewModel.load()
        #expect(fixture.connection.traffic().calls("agent.get").count == 2)
    }

    @Test(arguments: ["agent:updated", "agent:idle", "agent:status-changed"])
    func pendingViewMetadataRefreshCannotStartTrailingReadAfterTeardown(eventType: String) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        fixture.connection.pendingMethods = ["agent.get"]
        dispatchMetadataRefresh(eventType, store: viewModel.store, fixture: fixture)
        try await fixture.connection.waitForPendingRequests("agent.get")

        dispatchMetadataRefresh(eventType, store: viewModel.store, fixture: fixture)
        viewModel.teardownLiveStores()
        fixture.connection.pendingMethods = []
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await expectNever("a trailing metadata read owned by the closed view") {
            fixture.connection.traffic().calls("agent.get").count > 2
        }
        #expect(fixture.connection.traffic().pendingCount == 0)
    }

    @Test func closingOneViewKeepsAnotherViewsMetadataRefreshAlive() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel()
        await first.load()
        await second.load()
        fixture.connection.pendingMethods = ["agent.get"]
        dispatchMetadataRefresh("agent:updated", store: first.store, fixture: fixture)
        try await fixture.connection.waitForPendingRequests("agent.get")
        dispatchMetadataRefresh("agent:updated", store: second.store, fixture: fixture)
        first.teardownLiveStores()
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await fixture.connection.waitForPendingRequests("agent.get")
        fixture.parentMetadata["lastSeenMessageId"] = "new-seen"
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        try await waitUntil("the remaining view receives current metadata") { second.store.lastSeenMessageId == "new-seen" }
        #expect(first.store === second.store, "windows share metadata and transcript, not view-local divider state")
        #expect(fixture.connection.traffic().calls("agent.get").count == 3)
    }

    @Test func reconnectMetadataReadEndsWithItsViewActivation() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        fixture.details.invalidate(agentId: ConversationStartupFixture.parentId)
        fixture.connection.pendingMethods = ["agent.get"]
        let reconnect = Task { await viewModel.store.onReconnected() }
        defer { reconnect.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        fixture.details.invalidate(agentId: ConversationStartupFixture.parentId)
        viewModel.teardownLiveStores()
        fixture.connection.pendingMethods = []
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await reconnect.value
        #expect(fixture.connection.traffic().calls("agent.get").count == 2)
        #expect(viewModel.store.eventHandlerId == nil)
        #expect(fixture.connection.traffic().pendingCount == 0)
    }

    @Test(arguments: [false, true])
    func closedViewMetadataFailureCannotMarkReappearanceDeleted(rebind: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        fixture.connection.pendingMethods = ["agent.get"]
        dispatchMetadataRefresh("agent:updated", store: viewModel.store, fixture: fixture)
        try await fixture.connection.waitForPendingRequests("agent.get")
        viewModel.teardownLiveStores()
        viewModel.store.subscribeToStreaming(
            agentId: rebind ? "new-agent" : ConversationStartupFixture.parentId,
            workspaceId: ConversationStartupFixture.workspaceId
        )
        fixture.connection.failPending("agent.get", with: NSError(domain: "WebSocket", code: -32_602, userInfo: [
            NSError.intentErrorDataCodeKey: "not-found"
        ]))
        try await expectNever("an old metadata failure marking the new binding deleted") { viewModel.store.agentNotFound }
        #expect(fixture.connection.traffic().calls("agent.get").count == 2)
    }
}
