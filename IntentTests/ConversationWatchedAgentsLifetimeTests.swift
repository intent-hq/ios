import Foundation
@testable import Intent
import Testing

extension ConversationWatchedAgentsTests {
    @Test func disappearingRowsCancelReadsAndReappearanceCanRetry() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let consumer = UUID()
        let gate = TestGate()
        defer { gate.open() }
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.suspendedResponse = { method, _ in
            guard method == "agent.get" else { return nil }
            await gate.wait()
            return ["agent": ["id": "child", "workspaceId": "old-workspace", "name": "Obsolete"]]
        }
        watched.setVisible("child", visible: true, consumer: consumer)
        try await waitUntil("delayed child request") { fixture.connection.traffic(since: checkpoint).pendingCount == 1 }
        watched.releaseVisibility(consumer: consumer)
        // Let the cancellation handler retire this interest before reappearance.
        for _ in 0..<20 { await Task.yield() }
        fixture.connection.suspendedResponse = nil
        watched.setVisible("child", visible: true, consumer: consumer)
        try await waitUntil("new row after reappearance") { watched.row("child").hasSummary }
        #expect(watched.row("child").workspaceId == ConversationStartupFixture.workspaceId)
        let pending = fixture.connection.traffic(since: checkpoint)
        #expect(pending.requests.count == 2 && pending.pendingCount == 1)
        print("Watched cancellation before late reply (conditional): \(pending.summary)")
        gate.open()
        try await waitUntil("late reply remains in ledger") { fixture.connection.traffic(since: checkpoint).pendingCount == 0 }
        #expect(watched.row("child").agent.name == "Agent child")
        #expect(fixture.details.cached(agentId: "child")?.values["name"] as? String == "Agent child")
        print("Watched cancellation and late reply (conditional): \(fixture.connection.traffic(since: checkpoint).summary)")
        let total = try await finalTraffic(fixture)
        #expect(total.requests.count == 13)
        print("Watched cancellation all startup and cleanup: \(total.summary) methods=\(total.methodCounts)")
    }

    @Test func lastVisibilityCancellationCancelsQueuedWorkButKeepsDetailConsumer() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let consumer = UUID()
        fixture.connection.pendingMethods = ["agent.get"]
        watched.setVisible("child", visible: true, consumer: consumer)
        try await fixture.connection.waitForPendingRequests("agent.get")
        var joined = false
        let route = Task { joined = true; return try await fixture.details.load(agentId: "child") }
        defer { route.cancel() }
        try await waitUntil("route interested in same detail") { joined }
        watched.releaseVisibility(consumer: consumer)
        fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent("child")])
        _ = try await route.value
        #expect(fixture.connection.traffic().calls("agent.get").count == 2)
        #expect(fixture.connection.traffic().failures.isEmpty)
    }

    @Test func reconnectRejectsOldRepliesAndSeparatesBackendCaches() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let consumer = UUID()
        let gate = TestGate()
        defer { gate.open() }
        fixture.connection.suspendedResponse = { method, params in
            guard method == "agent.get", params["agentId"] as? String == "child" else { return nil }
            await gate.wait()
            return ["agent": ["id": "child", "workspaceId": "old", "name": "Old epoch"]]
        }
        watched.setVisible("child", visible: true, consumer: consumer)
        try await waitUntil("old connection child request") { fixture.connection.traffic().pendingCount == 1 }
        fixture.connection.releaseConnectionStateDelivery()
        fixture.connection.simulateDisconnect()
        watched.invalidateReads()
        fixture.connection.suspendedResponse = nil
        fixture.connection.simulateConnect()
        try await waitUntil("reconnected visible child") { watched.row("child").hasSummary }
        gate.open()
        try await waitUntil("all old and new replies completed") { fixture.connection.traffic().pendingCount == 0 }
        #expect(watched.row("child").agent.name == "Agent child")
        #expect(watched.row("child").workspaceId == ConversationStartupFixture.workspaceId)

        let other = ConversationStartupFixture()
        defer { other.stop() }
        other.watchedIds = ["child"]
        let otherModel = other.makeViewModel()
        await otherModel.load()
        #expect(!otherModel.store.watchedAgentCoordinator.row("child").hasSummary)
        #expect(other.details.cached(agentId: "child") == nil)
        #expect(other.connection.traffic().calls("agent.get").count == 1)
        let total = try await finalTraffic(fixture)
        print("Watched reconnect all startup, late reply and cleanup: \(total.summary) methods=\(total.methodCounts)")
    }
}

extension ConversationWatchedAgentsTests {
    @Test func cancelledTransportsKeepTheirSlotsUntilTheirRepliesActuallyFinish() async throws {
        let connection = RPCRecordingConnection()
        let details = AgentDetailStore(connection: connection)
        let gate = TestGate()
        defer { gate.open() }
        connection.suspendedResponse = { method, params in
            guard method == "agent.get", let id = params["agentId"] as? String else { return nil }
            if id.hasPrefix("old-") { await gate.wait() }
            return ["agent": ["id": id, "workspaceId": "workspace", "name": id]]
        }
        let old = (0..<4).map { index in
            Task {
                do {
                    _ = try await details.load(agentId: "old-\(index)")
                    return false
                } catch is CancellationError { return true } catch { Issue.record(error); return false }
            }
        }
        defer { old.forEach { $0.cancel() } }
        try await waitUntil("four real wire requests") { connection.traffic().pendingCount == 4 }
        old.forEach { $0.cancel() }
        let new = Task { try await details.load(agentId: "new") }
        defer { new.cancel() }
        try await expectNever("replacement exceeding occupied wire slots") { connection.traffic().requests.count > 4 }
        gate.open()
        _ = try await new.value
        for task in old { #expect(await task.value) }
        for index in 0..<4 { #expect(details.cached(agentId: "old-\(index)") == nil) }
        #expect(connection.traffic().requests.count == 5)
        #expect(connection.traffic().pendingCount == 0)
        print("Cancelled occupied slots and replacement: \(connection.traffic().summary)")
    }

    @Test func obsoleteSubscriptionCancellationCannotClearANewWatch() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["first"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        fixture.connection.pendingMethods = ["agent.cancelSubscriptions"]
        let cancellation = Task {
            await watched.cancelSubscriptions(agentId: ConversationStartupFixture.parentId, workspaceId: ConversationStartupFixture.workspaceId)
        }
        defer { cancellation.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.cancelSubscriptions")
        watched.reset()
        fixture.watchedIds = ["second"]
        await watched.fetchSubscriptions(agentId: "next-parent", workspaceId: "next-workspace")
        fixture.connection.resolvePending("agent.cancelSubscriptions", with: [:])
        await cancellation.value
        #expect(watched.watchedAgentIds == ["second"])
        #expect(watched.isWaitingForAgents)
    }
}

extension ConversationWatchedAgentsTests {
    func finalTraffic(_ fixture: ConversationStartupFixture) async throws -> RPCTraffic {
        let cleanupStart = fixture.connection.checkpoint
        fixture.stop()
        try await waitUntil("watched scenario cleanup settles") {
            let cleanup = fixture.connection.traffic(since: cleanupStart)
            return cleanup.calls("chat.unsubscribe").count == 1 && cleanup.calls("events.unsubscribe").count == 2 && cleanup.pendingCount == 0
        }
        let traffic = fixture.connection.traffic()
        #expect(traffic.pendingCount == 0)
        return traffic
    }
}
