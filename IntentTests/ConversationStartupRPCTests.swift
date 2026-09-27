import Foundation
@testable import Intent
import Testing

/// Metadata reuse regressions plus the remaining lifecycle/status baselines.
/// Later tasks replace those excess-call assertions with the four/eight-call budgets.
@MainActor
struct ConversationStartupRPCTests {
    private let currentQuietCounts = [
        "events.subscribe": 2, "chat.subscribe": 1, "agent.get": 1,
        "agent.getQueue": 1, "agent.getSubscriptions": 1, "hook.list": 1, "prMonitor.list": 1
    ]

    @Test func quietLoadRecordsActualCallsAndSnapshot() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let viewModel = fixture.makeViewModel()
        try await fixture.deliverInitialConnectionBeforeBinding()

        await viewModel.load()

        let traffic = fixture.connection.traffic()
        print("Quiet startup baseline: \(traffic.summary)")
        #expect(traffic.methodCounts == currentQuietCounts)
        #expect(traffic.pendingCount == 0)
        #expect(traffic.failures.isEmpty)
        #expect(traffic.requests.allSatisfy { $0.started.connectionGeneration == 1 })
        #expect(viewModel.filteredMessages.map(\.id) == [ConversationStartupFixture.messageId])
        #expect(!viewModel.isLoading)
        #expect(viewModel.store.lastSeenMessageId == ConversationStartupFixture.messageId)
        #expect(traffic.notifications.count == 1)
        #expect(traffic.requestBytes > 0 && traffic.responseBytes > 0 && traffic.notificationBytes > 0)

        let chat = try #require(traffic.calls("chat.subscribe").first)
        #expect(chat.params["agentId"] as? String == ConversationStartupFixture.parentId)
        #expect(chat.params["projection"] as? String == "slim")
        #expect(chat.params["deltaEncoding"] as? String == "incremental")
        #expect(chat.params["limit"] == nil && chat.params["sinceMessageId"] == nil)
        let snapshot = try #require(traffic.notifications.first)
        #expect(try #require(chat.completed).order < snapshot.received.order)
        #expect(chat.started.elapsed <= snapshot.received.elapsed)
        try expectListAfterAck(traffic, family: "hook:*", method: "hook.list")
        try expectListAfterAck(traffic, family: "prMonitor:*", method: "prMonitor.list")
    }

    @Test func warmWorkspaceStillRepeatsPerViewStatusReads() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        // Suppress connected replay to isolate load() cost. The replay cases
        // below include that work separately, in the same recorder.
        let first = fixture.makeViewModel()
        await first.load()
        for agentId in ["startup-second", ConversationStartupFixture.parentId] {
            let checkpoint = fixture.connection.checkpoint
            let next = fixture.makeViewModel(agentId: agentId)
            await next.load()
            let traffic = fixture.connection.traffic(since: checkpoint)
            print("Warm workspace startup baseline: \(traffic.summary)")
            var expected = currentQuietCounts
            if agentId == ConversationStartupFixture.parentId {
                for method in ["agent.get", "chat.subscribe", "agent.getQueue", "agent.getSubscriptions"] { expected[method] = nil }
            }
            #expect(traffic.methodCounts == expected)
            #expect(traffic.pendingCount == 0)
            #expect(traffic.failures.isEmpty)
            #expect(first.hookStore.hooks.isEmpty && next.hookStore.hooks.isEmpty)
            #expect(first.monitoredPrStore.monitors.isEmpty && next.monitoredPrStore.monitors.isEmpty)
        }
    }

    @Test func eventAckDoesNotBlockTranscriptAndDelayedQueueRemainsInTotals() async throws {
        let fixture = ConversationStartupFixture()
        let viewModel = fixture.makeViewModel()
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe", "agent.getQueue"]
        let load = Task { await viewModel.load() }
        defer { load.cancel(); fixture.stop() }
        try await connection.waitForPendingRequests("events.subscribe", count: 2)
        try await connection.waitForPendingRequests("agent.getQueue")
        try await waitUntil("snapshot while event ACKs and queue are suspended") {
            !viewModel.isLoading && viewModel.filteredMessages.map(\.id) == [ConversationStartupFixture.messageId]
        }
        let beforeQueue = connection.traffic()
        #expect(beforeQueue.calls("events.subscribe").allSatisfy { $0.completed == nil })
        #expect(beforeQueue.calls("chat.subscribe").count == 1)
        #expect(beforeQueue.pendingCount == 3)
        connection.pendingMethods.remove("events.subscribe")
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "side-1"])
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "side-2"])
        connection.resolvePending("agent.getQueue", with: ["queue": []])
        await load.value
        let settled = connection.traffic()
        #expect(settled.methodCounts == currentQuietCounts)
        #expect(settled.pendingCount == 0)
        #expect(settled.responseBytes > beforeQueue.responseBytes)
        #expect(settled.failures.isEmpty)
    }

    @Test(arguments: [0, 1, 5])
    func lateProposalConsumersReuseParentDetail(cardCount: Int) async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.parentMetadata["pendingProposals"] = [["proposalId": "proposal-1", "messageId": "proposal-message"]]
        await fixture.makeViewModel().load()
        let checkpoint = fixture.connection.checkpoint
        // ConversationView supplies one ProposalActionStore to its cards.
        let proposal = fixture.makeProposalStore()
        for _ in 0..<cardCount {
            await proposal.loadIfNeeded()
            #expect(proposal.pending["proposal-1"] == "proposal-message")
            #expect(proposal.loadError == nil)
        }
        let proposals = fixture.connection.traffic(since: checkpoint)
        print("Proposal mounts \(cardCount): \(fixture.connection.traffic().summary)")
        #expect(proposals.requests.isEmpty)
        #expect(fixture.connection.traffic().calls("agent.get").count == 1)
        #expect(fixture.connection.traffic().requests.count == 8)
        #expect(proposals.pendingCount == 0)
    }

    @Test func unrelatedWorkspaceRowsIncreaseWatchedResponseBytes() async throws {
        var measurements: [RPCTraffic] = []
        for unrelatedCount in [0, 1000] {
            let fixture = ConversationStartupFixture()
            defer { fixture.stop() }
            fixture.watchedIds = [ConversationStartupFixture.childId]
            fixture.unrelatedAgentCount = unrelatedCount
            let viewModel = fixture.makeViewModel()
            await viewModel.load()
            let traffic = fixture.connection.traffic()
            print("Watched fixture, unrelated agents \(unrelatedCount): \(traffic.summary)")
            measurements.append(traffic)
            #expect(viewModel.store.watchedAgents.map(\.id) == [ConversationStartupFixture.childId])
            #expect(traffic.calls("agent.list").count == 1)
            #expect(traffic.requests.count == 9)
            #expect(traffic.calls("chat.subscribe").count == 1)
            #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        }
        let small = try #require(measurements.first)
        let large = try #require(measurements.last)
        #expect(small.methodCounts == large.methodCounts)
        #expect(small.requestBytes == large.requestBytes)
        #expect(small.notificationBytes == large.notificationBytes)
        #expect(large.responseBytes > small.responseBytes)
        #expect(large.totalBytes > small.totalBytes)
    }

    @Test func deferredSelectedCatalogIsCountedAndReusedButSpecialistsStillRead() async {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.modelId = "fixture-model"
        fixture.providerId = "auggie"
        fixture.parentMetadata["specialist"] = "fixture-specialist"
        fixture.connection.responseMap["specialist.list"] = [
            "specialists": [["id": "fixture-specialist", "name": "Fixture specialist"]]
        ]
        fixture.connection.responseMap["models.list"] = [
            "models": [["id": "fixture-model", "name": "Fixture model", "provider": "auggie"]]
        ]
        for expectedModelReads in [1, 0] {
            let checkpoint = fixture.connection.checkpoint
            let viewModel = fixture.makeViewModel()
            await viewModel.load()
            // ConversationView's separate task calls this once metadata is
            // known; it belongs to the opening total even after load returns.
            await viewModel.loadModelCatalogIfNeeded()
            let traffic = fixture.connection.traffic(since: checkpoint)
            print("Startup with catalogs (model reads \(expectedModelReads)): \(traffic.summary)")
            #expect(traffic.calls("models.list").count == expectedModelReads)
            #expect(traffic.calls("models.list").allSatisfy { $0.params["providerId"] as? String == "auggie" })
            #expect(traffic.calls("specialist.list").count == 1)
            var expected = currentQuietCounts
            if expectedModelReads == 0 {
                for method in ["agent.get", "chat.subscribe", "agent.getQueue", "agent.getSubscriptions"] { expected[method] = nil }
            }
            expected["models.list"] = expectedModelReads == 1 ? 1 : nil
            expected["specialist.list"] = 1
            #expect(traffic.methodCounts == expected)
            #expect(traffic.calls("host.providerAuthStatus").isEmpty)
            #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
            #expect(viewModel.currentModelDisplayName == "Fixture model")
            #expect(viewModel.specialistName == "Fixture specialist")
        }
    }

    private func expectListAfterAck(_ traffic: RPCTraffic, family: String, method: String) throws {
        let subscription = try #require(traffic.calls("events.subscribe").first { request in
            request.params["eventTypes"] as? [String] == [family]
        })
        let list = try #require(traffic.calls(method).first)
        #expect(try #require(subscription.completed).order < list.started.order)
        #expect(list.params["workspaceId"] as? String == ConversationStartupFixture.workspaceId)
    }
}
