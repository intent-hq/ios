import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func settingsConnectionsRefreshLocalAndSyncedRecordsWithoutChangingWindow() {
        let bound = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: other.id)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: fake),
            connection: fake,
            backendID: BackendID(bound.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )
        coordinator.onOpenSettings()
        coordinator.refreshSyncedBackends()

        #expect(coordinator.savedConnections.first?.id == bound.id)
        #expect(Set(coordinator.savedConnections.map(\.displayName)) == ["10.0.0.1:1", "10.0.0.1:2", "Synced Mac"])
        #expect(coordinator.windowConnectionID == bound.id)
        #expect(persistence.activeConnection()?.id == other.id)
        #expect(fake.disconnectCallCount == 0)

        let invalidated = Mutex(false)
        withObservationTracking {
            _ = coordinator.savedConnections
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        var renamed = other
        renamed.displayName = "Renamed laptop"
        persistence.upsertConnection(renamed)
        coordinator.onScenePhaseActive()
        #expect(invalidated.withLock { $0 })
        #expect(coordinator.savedConnections.first { $0.id == other.id }?.displayName == "Renamed laptop")

        #expect(persistence.deleteConnection(id: other.id))
        coordinator.refreshSyncedBackends()
        #expect(!coordinator.savedConnections.contains { $0.id == other.id })
        #expect(coordinator.currentScreenDescription == "settings")
    }

    @Test @MainActor func settingsConnectionsRemainAvailableWhenSyncIsUnavailable() {
        let saved = persistence.upsertConnection(Self.makeConnection(port: 1))
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: fake),
            connection: fake,
            backendID: BackendID(saved.id),
            persistence: persistence,
            syncedRegistry: SyncedBackendRegistry(
                keychain: FakeSyncedKeychain(outcome: .failure(errSecNotAvailable)),
                accessGroup: "T.dev.intentapp.backends"
            )
        )
        coordinator.onOpenSettings()
        #expect(coordinator.refreshSyncedBackends() == nil)
        #expect(coordinator.savedConnections == [saved])
        #expect(fake.disconnectCallCount == 0)
    }

    @Test @MainActor func settingsSwitchUsesWindowOwnerWithoutDisconnectingSourceSession() {
        let source = persistence.upsertConnection(Self.makeConnection(port: 1))
        let target = persistence.upsertConnection(Self.makeConnection(port: 2))
        saveWorkspaceListScreen(for: source)
        saveWorkspaceListScreen(for: target)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: fake),
            connection: fake,
            backendID: BackendID(source.id),
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [])
        )
        var routed: [BackendID] = []
        coordinator.retargetWindow = { routed.append($0) }
        coordinator.onOpenSettings()
        coordinator.onSwitchConnection(id: target.id)

        #expect(routed == [BackendID(target.id)])
        #expect(persistence.activeConnection()?.id == target.id)
        #expect(persistence.loadLastScreen(for: target.id) == nil)
        #expect(persistence.loadLastScreen(for: source.id) != nil)
        #expect(fake.disconnectCallCount == 0)
        #expect(coordinator.windowConnectionID == source.id)
        #expect(coordinator.currentScreenDescription == "settings")
    }
}
