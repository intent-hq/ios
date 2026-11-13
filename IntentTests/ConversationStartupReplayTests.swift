import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupReplayTests {
    @Test func connectedReplayIsQuietAndActualReconnectReconcilesOnce() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.releaseConnectionStateDelivery()
        fixture.connection.simulateConnect()
        try await expectNever("requests from initial or repeated connected replay") {
            !fixture.connection.traffic(since: checkpoint).requests.isEmpty
        }
        fixture.connection.simulateDisconnect()
        fixture.connection.simulateConnect()
        fixture.connection.simulateConnect()
        try await waitForReconciliation(fixture.connection, since: checkpoint)
        let reconnect = fixture.connection.traffic(since: checkpoint)
        #expect(reconnect.methodCounts == [
            "chat.subscribe": 1, "agent.get": 1, "agent.getQueue": 1,
            "agent.getSubscriptions": 1, "events.subscribe": 2, "hook.list": 1, "prMonitor.list": 1, "browser.syncTabs": 1
        ])
        #expect(reconnect.requests.allSatisfy { $0.started.connectionGeneration == 2 })
        #expect(reconnect.notifications.count == 1)
        #expect(reconnect.failures.isEmpty)
        #expect(!viewModel.isLoading)
        #expect(viewModel.filteredMessages.map(\.id) == [ConversationStartupFixture.messageId])
    }

    @Test func repeatedConnectedValuesDoNotInvalidateTheSelectedCatalogOrRefetchMetadata() async throws {
        let fixture = ConversationStartupFixture()
        fixture.providerId = "auggie"
        fixture.modelId = "model"
        let model = fixture.makeViewModel()
        defer { fixture.stop() }
        await model.load()
        await model.loadModelCatalogIfNeeded()
        let generation = fixture.options.loadGeneration
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.releaseConnectionStateDelivery()
        fixture.connection.simulateConnect()
        fixture.connection.simulateConnect()
        try await expectNever("catalog invalidation from a repeated connected value") {
            fixture.options.loadGeneration != generation
        }
        await model.loadModelCatalogIfNeeded()
        #expect(fixture.connection.traffic(since: checkpoint).requests.isEmpty)
    }

    @Test func overlappingParentAndProposalReadsCoalesce() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let viewModel = fixture.makeViewModel()
        let proposal = fixture.makeProposalStore()
        connection.pendingMethods = ["agent.get"]
        let load = Task { await viewModel.load() }
        let refresh = Task { await proposal.loadIfNeeded() }
        defer { load.cancel(); refresh.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get")
        #expect(connection.traffic().calls("agent.get").count == 1)
        #expect(connection.traffic().calls("agent.get").allSatisfy { $0.responseJSON == nil })
        connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        await load.value
        await refresh.value
        #expect(connection.traffic().pendingCount == 0)
        #expect(connection.traffic().failures.isEmpty)
        #expect(proposal.loadError == nil)
    }

    private func waitForReconciliation(_ connection: RPCRecordingConnection, since checkpoint: Int) async throws {
        try await waitUntil("replay side-state requests and responses to settle") {
            let traffic = connection.traffic(since: checkpoint)
            return traffic.calls("agent.getSubscriptions").count == 1
                && traffic.calls("hook.list").count == 1
                && traffic.calls("prMonitor.list").count == 1
                && traffic.pendingCount == 0
        }
    }
}
