import Foundation
@testable import Intent
import Testing

@MainActor
struct ConversationStartupReplayTests {
    @Test func connectedReplayAfterLoadRepeatsWorkWithoutANewGeneration() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        await viewModel.load()
        let checkpoint = fixture.connection.checkpoint

        fixture.connection.releaseConnectionStateDelivery()
        try await waitForReconciliation(fixture.connection, since: checkpoint)
        let replay = fixture.connection.traffic(since: checkpoint)
        #expect(replay.calls("chat.subscribe").count == 1)
        #expect(replay.calls("agent.get").count == 1)
        #expect(replay.calls("events.subscribe").count == 3)
        #expect(replay.calls("events.unsubscribe").count == 1)
        #expect(replay.requests.count == 10)
        #expect(replay.requests.allSatisfy { $0.started.connectionGeneration == 1 })
        #expect(replay.failures.isEmpty)

        let reconnectCheckpoint = fixture.connection.checkpoint
        fixture.connection.simulateDisconnect()
        fixture.connection.simulateConnect()
        try await waitForReconciliation(fixture.connection, since: reconnectCheckpoint)
        let reconnect = fixture.connection.traffic(since: reconnectCheckpoint)
        #expect(reconnect.methodCounts == replay.methodCounts)
        #expect(reconnect.requests.allSatisfy { $0.started.connectionGeneration == 2 })
        #expect(reconnect.notifications.count == 1)
        #expect(reconnect.failures.isEmpty)
        #expect(!viewModel.isLoading)
        #expect(viewModel.filteredMessages.map(\.id) == [ConversationStartupFixture.messageId])
    }

    @Test func connectedReplayDuringEventAckStartsAnExtraTranscriptLoad() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let viewModel = fixture.makeViewModel()
        connection.pendingMethods = ["events.subscribe"]
        let load = Task { await viewModel.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("events.subscribe")
        #expect(!connection.didCallMethod("chat.subscribe"))

        connection.releaseConnectionStateDelivery()
        try await waitUntil("replay snapshot while initial event ACK is held") {
            viewModel.filteredMessages.map(\.id) == [ConversationStartupFixture.messageId]
                && connection.traffic().calls("agent.get").count == 1
        }
        try await expectNever("another event registration while the first is suspended") {
            connection.paramsForMethod("events.subscribe").count > 1
        }

        connection.pendingMethods.remove("events.subscribe")
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "startup-events"])
        await load.value
        let traffic = connection.traffic()
        #expect(traffic.calls("chat.subscribe").count == 2)
        #expect(traffic.calls("agent.getQueue").count == 2)
        #expect(traffic.calls("agent.get").count == 3)
        #expect(traffic.notifications.count == 2)
        #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        #expect(traffic.requests.allSatisfy { $0.started.connectionGeneration == 1 })
    }

    @Test func overlappingParentAndProposalReadsAreAllRecorded() async throws {
        let fixture = ConversationStartupFixture()
        let connection = fixture.connection
        let viewModel = fixture.makeViewModel()
        let proposal = fixture.makeProposalStore()
        connection.pendingMethods = ["agent.get"]
        let load = Task { await viewModel.load() }
        let refresh = Task { await proposal.refresh() }
        defer { load.cancel(); refresh.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("agent.get", count: 3)
        #expect(connection.traffic().calls("agent.get").count == 3)
        #expect(connection.traffic().calls("agent.get").allSatisfy { $0.responseJSON == nil })
        for _ in 0..<3 {
            connection.resolvePending("agent.get", with: ["agent": fixture.agent(ConversationStartupFixture.parentId)])
        }
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
