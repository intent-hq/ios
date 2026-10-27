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

    @Test @MainActor func historyEntryOnAnotherDeviceSwitchesTheWindowWhereMultipleWindowsAreSupported() {
        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        var retargeted: BackendID?
        coordinator.retargetWindow = { retargeted = $0 }
        let manager = makeHistoryNotificationManager()
        manager.supportsMultipleWindows = true
        var opened: BackendID?
        manager.openBackendWindow = { opened = $0 }
        manager.registerAgentSelectionHandler(for: Self.windowBackend) { _, _, _, _ in }
        let laptop = BackendID(UUID())

        coordinator.onSelectHistoryEntry(historyEntry(on: laptop.connectionID), notifications: manager)

        #expect(opened == nil)
        #expect(retargeted == laptop)
        var delivered: String?
        manager.registerAgentSelectionHandler(for: laptop) { agentId, _, _, _ in delivered = agentId }
        #expect(delivered == "agent-1")
    }

    @Test @MainActor func historyEntryOnAnotherDeviceRaisesItsOpenWindow() {
        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        var retargeted: BackendID?
        coordinator.retargetWindow = { retargeted = $0 }
        let manager = makeHistoryNotificationManager()
        manager.supportsMultipleWindows = true
        let laptop = BackendID(UUID())
        var delivered: String?
        manager.registerAgentSelectionHandler(for: laptop) { agentId, _, _, _ in delivered = agentId }

        coordinator.onSelectHistoryEntry(historyEntry(on: laptop.connectionID), notifications: manager)

        #expect(delivered == "agent-1")
        #expect(retargeted == nil)
    }

    @Test(arguments: ["deleted", "archived"])
    @MainActor func removedWorkspaceEventDropsThisDevicesHistoryForIt(removal: String) async throws {
        let fixture = makeRemovalCoordinator()
        try await fixture.fake.connect(
            hosts: fixture.saved.server.hosts,
            port: fixture.saved.server.port,
            token: fixture.saved.token,
            certFingerprint: fixture.saved.server.certFingerprint,
            tcAddress: nil
        )
        let here = fixture.saved.id
        fixture.coordinator.agentHistory.record(historyEntry(on: here, workspaceId: "kept", agentId: "kept"))
        fixture.coordinator.agentHistory.record(historyEntry(on: here, workspaceId: "gone", agentId: "removed"))
        fixture.coordinator.agentHistory.record(historyEntry(on: UUID(), workspaceId: "gone", agentId: "other-device"))

        fixture.store.handleEvent("event", params: ["event": removalEvent(removal)] as [String: Any])

        #expect(Set(fixture.coordinator.agentHistory.entries.map(\.agentId)) == ["kept", "other-device"])
    }

    @Test(arguments: ["pairing", "otherDevice", "disconnected"])
    @MainActor func removalEventsKeepHistoryUnlessTheSocketReachesThisDevice(socket: String) async throws {
        let fixture = makeRemovalCoordinator()
        switch socket {
        case "pairing":
            try await PairingConnectionContext.$attemptID.withValue(UUID()) {
                try await fixture.fake.connect(
                    hosts: fixture.saved.server.hosts,
                    port: fixture.saved.server.port,
                    token: fixture.saved.token,
                    certFingerprint: fixture.saved.server.certFingerprint,
                    tcAddress: nil
                )
            }
        case "otherDevice":
            try await fixture.fake.connect(hosts: ["10.0.0.2"], port: 4200, token: "tok-other", certFingerprint: nil, tcAddress: nil)
        default:
            break
        }
        fixture.coordinator.agentHistory.record(historyEntry(on: fixture.saved.id, workspaceId: "gone", agentId: "kept"))

        fixture.store.handleEvent("event", params: ["event": removalEvent("deleted")] as [String: Any])

        #expect(fixture.coordinator.agentHistory.entries.count == 1)
    }

    @Test @MainActor func unrelatedWorkspaceUpdatesKeepHistory() async throws {
        let fixture = makeRemovalCoordinator()
        try await fixture.fake.connect(hosts: fixture.saved.server.hosts, port: fixture.saved.server.port, token: fixture.saved.token, certFingerprint: nil, tcAddress: nil)
        fixture.coordinator.agentHistory.record(historyEntry(on: fixture.saved.id, workspaceId: "kept"))

        fixture.store.handleEvent("event", params: [
            "event": [
                "type": "workspace:updated",
                "workspaceId": "kept",
                "data": ["workspaceId": "kept", "changes": ["archived": false, "status": "Active"]]
            ] as [String: Any]
        ] as [String: Any])

        #expect(fixture.coordinator.agentHistory.entries.count == 1)
    }

    @MainActor
    private func makeRemovalCoordinator() -> HistoryRemovalFixture {
        let saved = persistence.upsertConnection(Self.makeConnection(port: HistoryRemovalFixture.savedPort))
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: BackendID(saved.id),
            persistence: persistence
        )
        return HistoryRemovalFixture(coordinator: coordinator, store: store, fake: fake, saved: saved)
    }

    private func removalEvent(_ removal: String) -> [String: Any] {
        let data: [String: Any] = removal == "deleted"
            ? ["workspaceId": "gone"]
            : ["workspaceId": "gone", "changes": ["archived": true]]
        return [
            "type": removal == "deleted" ? "workspace:deleted" : "workspace:updated",
            "workspaceId": "gone",
            "data": data
        ]
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

@MainActor
private struct HistoryRemovalFixture {
    static let savedPort = 4100

    let coordinator: AppCoordinator
    let store: WorkspaceStore
    let fake: FakeConnectionManager
    let saved: StoredConnection
}
