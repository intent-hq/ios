import Foundation
@testable import Intent
import Testing

extension ConversationWatchedAgentsTests {
    @Test func fourWireSlotsAcrossParentsAndDetailConsumersCancelQueuedRows() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = (0..<8).map { "child-\($0)" }
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel(agentId: "other-parent")
        await first.load()
        await second.load()
        let firstRows = first.store.watchedAgentCoordinator
        let secondRows = second.store.watchedAgentCoordinator
        let consumer = UUID()
        let other = UUID()
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.pendingMethods = ["agent.get"]
        for id in fixture.watchedIds.prefix(4) { firstRows.setVisible(id, visible: true, consumer: consumer) }
        try await fixture.connection.waitForPendingRequests("agent.get", count: 4)
        for id in fixture.watchedIds.suffix(4) { firstRows.setVisible(id, visible: true, consumer: consumer) }
        secondRows.setVisible("child-0", visible: true, consumer: other)
        var joined = false
        let detail = Task { joined = true; return try await fixture.details.load(agentId: "child-0") }
        defer { detail.cancel() }
        try await waitUntil("detail consumer joined") { joined }
        firstRows.setVisible("child-7", visible: false, consumer: consumer)
        firstRows.setVisible("child-0", visible: false, consumer: consumer)
        try await expectNever("fifth concurrent request") { fixture.connection.pendingRequestCount("agent.get") > 4 }
        #expect(fixture.connection.traffic(since: checkpoint).calls("agent.get").count == 4)
        // Resolve in actual wire-start order, allowing queued interests to take each slot.
        for index in 0..<7 {
            try await waitUntil("next pending child") { fixture.connection.pendingRequestCount("agent.get") > 0 }
            let requests = fixture.connection.traffic(since: checkpoint).calls("agent.get")
            let id = try #require(requests[index].params["agentId"] as? String)
            fixture.connection.resolvePending("agent.get", with: ["agent": fixture.agent(id)])
            try await waitUntil("completed child") { firstRows.row(id).hasSummary }
            #expect(fixture.connection.pendingRequestCount("agent.get") <= 4)
        }
        _ = try await detail.value
        let traffic = fixture.connection.traffic(since: checkpoint)
        #expect(traffic.calls("agent.get").count == 7)
        #expect(!traffic.calls("agent.get").contains { $0.params["agentId"] as? String == "child-7" })
        #expect(traffic.calls("agent.get").filter { $0.params["agentId"] as? String == "child-0" }.count == 1)
        #expect(traffic.pendingCount == 0 && traffic.failures.isEmpty)
        print("Bounded watched details: \(traffic.summary)")
    }

    @Test func selectedOffscreenChildUsesCanonicalWorkspaceAndSharedRouteDetail() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["cross-child"]
        let model = fixture.makeViewModel()
        await model.load()
        let connection = fixture.connection
        connection.pendingMethods = ["agent.get"]
        let selected = Task { await model.store.watchedAgentCoordinator.selectedAgent("cross-child") }
        defer { selected.cancel() }
        try await connection.waitForPendingRequests("agent.get")
        let row: [String: Any] = ["id": "cross-child", "workspaceId": "child-workspace", "name": "Cross child", "status": "idle"]
        connection.resolvePending("agent.get", with: ["agent": row])
        let result = await selected.value
        #expect(result?.workspaceId == "child-workspace")
        #expect(result?.agent.name == "Cross child")
        _ = try await fixture.details.load(agentId: "cross-child", workspaceId: "child-workspace")
        #expect(connection.traffic().calls("agent.get").count == 2)
        #expect(connection.traffic().calls("agent.get").allSatisfy { $0.params["workspaceId"] == nil })
        #expect(connection.traffic().calls("chat.subscribe").count == 1)
        #expect(connection.traffic().calls("agent.getSubscriptions").count == 1)
    }

    @Test func failedVisibleReadRetriesAndDoesNotBecomeCompleted() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        let watched = model.store.watchedAgentCoordinator
        let consumer = UUID()
        let checkpoint = fixture.connection.checkpoint
        fixture.connection.errorMap["agent.get"] = NSError(domain: "Transient", code: 1)
        watched.setVisible("child", visible: true, consumer: consumer)
        try await waitUntil("retryable failure") { watched.errors["child"] != nil }
        #expect(!watched.row("child").isCompleted)
        #expect(!watched.row("child").hasSummary)
        fixture.connection.errorMap["agent.get"] = nil
        watched.retry("child")
        try await waitUntil("retried row") { watched.row("child").hasSummary }
        let traffic = fixture.connection.traffic(since: checkpoint)
        #expect(traffic.calls("agent.get").count == 2)
        #expect(traffic.failures.count == 1 && traffic.pendingCount == 0)
        print("Watched failure and retry (conditional): \(traffic.summary)")
        let total = try await finalTraffic(fixture)
        #expect(total.requests.count == 13 && total.failures.count == 1)
        print("Watched failure and retry all startup and cleanup: \(total.summary) methods=\(total.methodCounts)")
    }

    @Test(arguments: [false, true])
    func childIdentityMustIncludeMatchingIdAndCanonicalWorkspace(wrongId: Bool) async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        fixture.watchedIds = ["child"]
        let model = fixture.makeViewModel()
        await model.load()
        fixture.connection.pendingMethods = ["agent.get"]
        let watched = model.store.watchedAgentCoordinator
        let selected = Task { await watched.selectedAgent("child") }
        defer { selected.cancel() }
        try await fixture.connection.waitForPendingRequests("agent.get")
        var row: [String: Any] = ["id": wrongId ? "wrong" : "child", "name": "Child"]
        if wrongId { row["workspaceId"] = "workspace" }
        fixture.connection.resolvePending("agent.get", with: ["agent": row])
        #expect(await selected.value == nil)
        #expect(watched.errors["child"] != nil)
        #expect(!watched.row("child").hasSummary)
        fixture.connection.pendingMethods = []
        #expect(await watched.selectedAgent("child") != nil)
        #expect(fixture.connection.traffic().calls("agent.get").count == 3)
    }
}
