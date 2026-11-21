import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func refreshSyncedBackends_undecodableRegistryIsPreservedAndFlagged() {
        resetConnectionState()
        defer { resetConnectionState() }

        let undecodable = Data("{\"v\": 99, \"schema\": \"future\"}".utf8)
        #expect(persistence.saveDataToKeychain(
            data: undecodable,
            account: persistence.keychainAccountConnections
        ))
        let registry = BackendSessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )
        #expect(!coordinator.savedConnectionsUndecodable)

        coordinator.onScenePhaseActive()

        #expect(coordinator.savedConnectionsUndecodable)
        #expect(persistence.loadDataFromKeychain(
            account: persistence.keychainAccountConnections
        ) == undecodable)
        #expect(persistence.isConnectionRegistryUndecodable())
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .loading = coordinator.currentScreen {
        } else {
            Issue.record("Expected .loading, got \(coordinator.currentScreen)")
        }

        persistence.deleteFromKeychain(account: persistence.keychainAccountConnections)
        let outcome = coordinator.refreshSyncedBackends()
        #expect(outcome?.registryUndecodable == false)
        #expect(outcome?.addedIds.count == 1)
        #expect(!coordinator.savedConnectionsUndecodable)
    }
}
