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

    @Test @MainActor func fetchedWorkspaceListDropsHistoryForRemovedWorkspaces() async throws {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.simulateConnect()
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )
        let here = Self.windowBackend.connectionID
        let elsewhere = UUID()
        for (connectionId, workspaceId) in [
            (here, "kept"), (here, "deleted"), (here, "archived"), (elsewhere, "deleted")
        ] {
            coordinator.agentHistory.record(historyEntry(on: connectionId, workspaceId: workspaceId, agentId: "agent-\(workspaceId)"))
        }

        store.publishFetchedWorkspaces([
            Self.makeWorkspace(id: "kept"),
            Self.makeWorkspace(id: "archived", status: "archived")
        ])

        try await waitUntil("history pruned after the workspace list loads") {
            coordinator.agentHistory.entries.count == 2
        }
        let remaining = coordinator.agentHistory.entries.map { "\($0.connectionId == here ? "here" : "elsewhere")/\($0.workspaceId)" }
        #expect(Set(remaining) == ["here/kept", "elsewhere/deleted"])
    }

    @Test @MainActor func disconnectedWindowNeverPrunesHistory() {
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(forTesting: true),
            connection: FakeConnectionManager(),
            backendID: Self.windowBackend,
            persistence: persistence
        )
        coordinator.agentHistory.record(historyEntry(on: Self.windowBackend.connectionID))

        coordinator.pruneAgentHistory(keeping: [])

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
