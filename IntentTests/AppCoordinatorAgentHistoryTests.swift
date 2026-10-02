import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func openingConversationsRecordsThemWithWorkspaceAndDevice() throws {
        let store = WorkspaceStore(forTesting: true)
        store.workspaces = [try #require(WorkspaceStore.parseWorkspace(["id": "workspace-1", "title": "Payments"]))]
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: FakeConnectionManager(),
            backendID: Self.windowBackend,
            persistence: persistence
        )

        coordinator.onSelectAgent("agent-1", workspaceId: "workspace-1", agentName: "Builder")
        coordinator.onBackToWorkspaceDetail()
        coordinator.onSelectAgent("agent-2", workspaceId: "workspace-1", agentName: "Reviewer")

        let entries = coordinator.agentHistory.entries
        #expect(entries.map(\.agentId) == ["agent-2", "agent-1"])
        #expect(entries.allSatisfy { $0.connectionId == Self.windowBackend.connectionID })
        #expect(entries.first?.workspaceTitle == "Payments")
    }

    @Test @MainActor func historyEntryOnThisDeviceOpensTheConversation() {
        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        var retargeted: BackendID?
        coordinator.retargetWindow = { retargeted = $0 }

        coordinator.onSelectHistoryEntry(
            historyEntry(on: Self.windowBackend.connectionID),
            notifications: makeHistoryNotificationManager()
        )

        guard case let .agentConversation(agentId, workspaceId, _) = coordinator.currentScreen else {
            Issue.record("Expected the conversation, got \(coordinator.currentScreen)")
            return
        }
        #expect(agentId == "agent-1")
        #expect(workspaceId == "workspace-1")
        #expect(retargeted == nil)
    }

    @Test @MainActor func historyEntryOnAnotherDeviceSwitchesTheWindowThenOpensTheAgent() {
        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        var retargeted: BackendID?
        coordinator.retargetWindow = { retargeted = $0 }
        let manager = makeHistoryNotificationManager()
        manager.registerAgentSelectionHandler(for: Self.windowBackend) { _, _, _, _ in }
        let laptop = BackendID(UUID())

        coordinator.onSelectHistoryEntry(historyEntry(on: laptop.connectionID), notifications: manager)

        #expect(retargeted == laptop)
        var delivered: (agentId: String, connectionId: UUID)?
        manager.registerAgentSelectionHandler(for: laptop) { agentId, _, _, connectionId in
            delivered = (agentId, connectionId)
        }
        #expect(delivered?.agentId == "agent-1")
        #expect(delivered?.connectionId == laptop.connectionID)
    }

    @Test @MainActor func historyEntryOnAnotherDeviceOpensItsOwnWindowWhereSupported() {
        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        var retargeted: BackendID?
        coordinator.retargetWindow = { retargeted = $0 }
        let manager = makeHistoryNotificationManager()
        manager.supportsMultipleWindows = true
        var opened: BackendID?
        manager.openBackendWindow = { opened = $0 }
        let laptop = BackendID(UUID())

        coordinator.onSelectHistoryEntry(historyEntry(on: laptop.connectionID), notifications: manager)

        #expect(opened == laptop)
        #expect(retargeted == nil)
    }

    @Test(arguments: ["deleted", "archived"])
    @MainActor func removedWorkspaceEventDropsThisDevicesHistoryForIt(removal: String) {
        let data: [String: Any] = removal == "deleted"
            ? ["workspaceId": "gone"]
            : ["workspaceId": "gone", "changes": ["archived": true]]
        let event: [String: Any] = [
            "type": removal == "deleted" ? "workspace:deleted" : "workspace:updated",
            "workspaceId": "gone",
            "data": data
        ]
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: FakeConnectionManager(),
            backendID: Self.windowBackend,
            persistence: persistence
        )
        let here = Self.windowBackend.connectionID
        let elsewhere = UUID()
        coordinator.agentHistory.record(historyEntry(on: here, workspaceId: "kept", agentId: "kept"))
        coordinator.agentHistory.record(historyEntry(on: here, workspaceId: "gone", agentId: "removed"))
        coordinator.agentHistory.record(historyEntry(on: elsewhere, workspaceId: "gone", agentId: "other-device"))

        store.handleEvent("event", params: ["event": event] as [String: Any])

        #expect(Set(coordinator.agentHistory.entries.map(\.agentId)) == ["kept", "other-device"])
    }

    @Test @MainActor func unrelatedWorkspaceUpdatesKeepHistory() {
        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: FakeConnectionManager(),
            backendID: Self.windowBackend,
            persistence: persistence
        )
        coordinator.agentHistory.record(historyEntry(on: Self.windowBackend.connectionID, workspaceId: "kept"))

        store.handleEvent("event", params: [
            "event": [
                "type": "workspace:updated",
                "workspaceId": "kept",
                "data": ["workspaceId": "kept", "changes": ["archived": false, "status": "Active"]]
            ] as [String: Any]
        ] as [String: Any])

        #expect(coordinator.agentHistory.entries.count == 1)
    }

    private func historyEntry(
        on connectionId: UUID,
        workspaceId: String = "workspace-1",
        agentId: String = "agent-1"
    ) -> AgentHistoryEntry {
        AgentHistoryEntry(
            connectionId: connectionId,
            workspaceId: workspaceId,
            workspaceTitle: "Payments",
            agentId: agentId,
            agentName: "Builder",
            visitedAt: .now
        )
    }

    @MainActor
    private func makeHistoryNotificationManager() -> NotificationManager {
        NotificationManager(
            localNotificationService: LocalNotificationService(center: NotificationManagerFakeCenter()),
            registerEvents: false
        )
    }
}
