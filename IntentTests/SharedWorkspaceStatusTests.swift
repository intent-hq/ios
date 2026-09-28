import Foundation
@testable import Intent
import Testing

@MainActor
struct SharedWorkspaceStatusTests {
    @Test func workspaceRowAndTwoConversationWindowsShareTheSessionMonitorFeed() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let first = fixture.makeViewModel()
        let second = fixture.makeViewModel(agentId: "second-agent")
        fixture.session.prMonitorsStore.retain(workspaceId: ConversationStartupFixture.workspaceId)
        await fixture.session.prMonitorsStore.seed(workspaceId: ConversationStartupFixture.workspaceId)
        await first.load()
        await second.load()
        let traffic = fixture.connection.traffic()
        #expect(traffic.calls("events.subscribe").count == 2)
        #expect(traffic.calls("hook.list").count == 1)
        #expect(traffic.calls("prMonitor.list").count == 1)
        #expect(traffic.calls("chat.subscribe").count == 2)
        #expect(traffic.calls("agent.get").count == 2)
        let monitors = try #require(traffic.calls("events.subscribe").first { request in
            request.params["eventTypes"] as? [String] == ["prMonitor:*"]
        })
        #expect(monitors.params["workspaceId"] == nil)
        #expect(monitors.params["replaceGroup"] as? String == "ios-pr-monitors-rows")
        print("Shared rows and windows: \(traffic.summary)")
    }

    @Test func simultaneousRowsCannotSeedBeforeTheSharedFeedAcknowledges() async throws {
        let fixture = ConversationStartupFixture()
        defer { fixture.stop() }
        let connection = fixture.connection
        connection.pendingMethods = ["events.subscribe"]
        let rows = fixture.session.prMonitorsStore
        rows.retain(workspaceId: "workspace-a")
        rows.retain(workspaceId: "workspace-b")
        let first = Task { await rows.seed(workspaceId: "workspace-a") }
        let second = Task { await rows.seed(workspaceId: "workspace-b") }
        defer { first.cancel(); second.cancel() }
        try await connection.waitForPendingRequests("events.subscribe")
        try await expectNever("list before the feed ACK") { connection.didCallMethod("prMonitor.list") }
        connection.resolvePending("events.subscribe", with: ["subscriptionId": "shared-feed"])
        await first.value
        await second.value
        #expect(connection.paramsForMethod("events.subscribe").count == 1)
        #expect(connection.paramsForMethod("prMonitor.list").count == 2)
    }
}
