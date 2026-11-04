import Foundation
@testable import Intent
import Testing
import UIKit

/// The idle-alert suppression read walks every `agent.list` page (protocol
/// "Paged agent lists and queues"): an active agent on a later page still
/// suppresses the alert, and a walk that fails falls back to alerting.
@Suite("NotificationManager paged agent reads")
@MainActor
struct NotificationAgentListPagingTests {
    private static let connectionId = UUID(uuid: (
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33,
        0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33, 0x33
    ))

    private func makeManager(_ connection: FakeConnectionManager) -> (NotificationManager, NotificationManagerFakeCenter) {
        let center = NotificationManagerFakeCenter()
        let manager = NotificationManager(
            localNotificationService: LocalNotificationService(center: center),
            applicationState: { .active },
            activeConnectionId: { Self.connectionId },
            presentFeedback: {},
            windowEmitsFeedbackSound: false,
            connection: connection,
            workspaceStore: WorkspaceStore(forTesting: true),
            registerEvents: false
        )
        return (manager, center)
    }

    private var idleEvent: [String: Any] {
        [
            "event": [
                "type": "agent:idle",
                "workspaceId": "ws-1",
                "data": ["agentId": "agent-1", "agentName": "Idle agent"]
            ] as [String: Any]
        ]
    }

    @Test func activeAgentOnALaterPageSuppressesTheIdleAlert() async throws {
        let fake = FakeConnectionManager()
        var active = AgentListPagingTests.rows(201...201)[0]
        active["status"] = "active"
        fake.responseQueueMap["agent.list"] = [
            AgentListPagingTests.page(AgentListPagingTests.rows(1...200), next: "t1"),
            AgentListPagingTests.page([active], next: nil)
        ]
        let (manager, center) = makeManager(fake)

        manager.handleEvent(idleEvent, from: nil)

        try await fake.waitForRequests("agent.list", count: 2)
        try await expectNever("an idle alert while an agent on the last page is active") {
            manager.currentToast != nil || !center.requests.isEmpty
        }
        let sent = fake.paramsForMethod("agent.list")
        #expect(sent.map { $0["nextToken"] as? String } == [nil, "t1"])
        #expect(sent.allSatisfy { $0["workspaceId"] as? String == "ws-1" && $0["limit"] as? Int == PagedReads.agentPageLimit })
    }

    @Test func idleWorkspaceAcrossEveryPageAlerts() async throws {
        let fake = FakeConnectionManager()
        fake.responseQueueMap["agent.list"] = [
            AgentListPagingTests.page(AgentListPagingTests.rows(1...200), next: "t1"),
            AgentListPagingTests.page(AgentListPagingTests.rows(201...202), next: nil)
        ]
        let (manager, _) = makeManager(fake)

        manager.handleEvent(idleEvent, from: nil)

        try await waitUntil("the idle toast after reading every page") { manager.currentToast != nil }
        #expect(manager.currentToast?.agentId == "agent-1")
        #expect(fake.paramsForMethod("agent.list").count == 2)
    }

    @Test func pageErrorMidWalkFallsBackToTheAlert() async throws {
        let fake = FakeConnectionManager()
        // The second page has no configured reply, so it fails.
        fake.responseQueueMap["agent.list"] = [AgentListPagingTests.page(AgentListPagingTests.rows(1...200), next: "t1")]
        let (manager, _) = makeManager(fake)

        manager.handleEvent(idleEvent, from: nil)

        try await waitUntil("the fail-open idle toast") { manager.currentToast != nil }
        #expect(fake.paramsForMethod("agent.list").count == 2)
    }
}
