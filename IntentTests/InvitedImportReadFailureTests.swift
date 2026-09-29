import Foundation
@testable import Intent
import Security
import Testing

extension AppCoordinatorInvitedSyncTests {
    @Test func unreadableFinalSnapshotRetainsOnlyAuthoritativeSuppression() throws {
        let invited = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        let other = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session("C")))
        let outcome = InvitedImportOutcome(before: [invited, other], after: .failed(.unavailable(errSecNotAvailable)), suppressed: [invited.id])
        #expect(outcome.removedIds == [invited.id])
        #expect(outcome.addedIds.isEmpty)
        #expect(outcome.updatedIds.isEmpty)
    }

    @Test func lateLocalReadFailurePreservesInvitedAndOwnerSessionsUntilRecovery() async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        let storage = FakeSecItemStore()
        store.persistence.keychainStorage = SecItemKeychainStorage(security: storage.securityCalls())
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let invited = try #require(store.persistence.loadConnections().first)
        let invitedLive = FakeConnectionManager()
        invitedLive.currentPrincipal = InvitedSessionFixtures.principal()
        let ownerLive = FakeConnectionManager()
        let records = try await Self.saveLiveRecords(invited, lives: [invitedLive, ownerLive], persistence: store.persistence)
        let registry = BackendSessionRegistry { id in
            Self.session(id: id, connection: id == BackendID(invited.id) ? invitedLive : ownerLive, persistence: store.persistence)
        }
        for record in records { _ = registry.attach(BackendID(record.id)) }
        defer { for record in records { registry.detach(BackendID(record.id)) } }
        let unbound = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: WorkspaceStore(connectionManager: unbound), connection: unbound, persistence: store.persistence, sessionRegistry: registry)
        coordinator.currentScreen = .pairing
        coordinator.refreshSavedConnectionsPresentation()
        let savedBefore = coordinator.savedConnections
        let bytesBefore = storage.items
        let gate = TestGate()
        defer { gate.open() }
        var authenticating = false
        coordinator.refreshInvitedConnections { _ in
            authenticating = true
            await gate.wait()
            return InvitedSessionFixtures.principal()
        }
        try await waitUntil("invited authentication before local read failure") { authenticating }
        storage.readFailures[store.persistence.keychainAccountConnections] = errSecInteractionNotAllowed
        gate.open()
        await coordinator.invitedRefreshTask?.value
        #expect(storage.items == bytesBefore)
        #expect(coordinator.savedConnections == savedBefore)
        #expect(coordinator.pairingShowsSavedConnections)
        Self.expectRetainedSessions(records, lives: [invitedLive, ownerLive], registry: registry, persistence: store.persistence)
        storage.readFailures = [:]
        coordinator.refreshInvitedConnections { _ in InvitedSessionFixtures.principal() }
        await coordinator.invitedRefreshTask?.value
        #expect(Set(coordinator.savedConnections.map(\.id)) == Set(records.map(\.id)))
        #expect(registry.removedBackendIDs.isEmpty)
        #expect(invitedLive.connectionState == .connected)
        #expect(ownerLive.connectionState == .connected)
    }

    private static func saveLiveRecords(_ invited: StoredConnection, lives: [FakeConnectionManager], persistence: PersistenceManager) async throws -> [StoredConnection] {
        var owner = StoredConnection(
            server: PairedServer(hosts: ["owner.example"], port: invited.server.port, name: "Owner", pairedAt: Date()), token: "owner-token"
        )
        owner.principal = .demoOwner
        let records = [invited, owner]
        #expect(persistence.saveConnectionsLocked(records))
        for (record, live) in zip(records, lives) {
            try await live.connect(hosts: record.server.hosts, port: record.server.port, token: record.token, certFingerprint: record.server.certFingerprint, tcAddress: nil)
            persistence.saveLastScreen(.init(screen: "workspaceList", workspaceId: nil, agentId: nil, agentName: nil, noteId: nil, noteTitle: nil), for: record.id)
        }
        return records
    }

    private static func expectRetainedSessions(_ records: [StoredConnection], lives: [FakeConnectionManager], registry: BackendSessionRegistry, persistence: PersistenceManager) {
        for (record, live) in zip(records, lives) {
            #expect(!registry.isBackendRemoved(BackendID(record.id)))
            #expect(live.connectionState == .connected)
            #expect(live.disconnectCallCount == 0)
            #expect(persistence.loadLastScreen(for: record.id)?.screen == "workspaceList")
        }
    }

    @Test func observedRemovalStillSuppressesInvitedSessionWhenCredentialWriteFails() async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.persistence.loadConnections().first)
        let removal = try InvitedSessionFixtures.removal()
        cloud.items[removal.account] = removal.data
        store.storage.setSaveFailure(true)
        let outcome = await store.persistence.refreshInvitedSessions { _ in
            Issue.record("A removed credential was authenticated")
            return InvitedSessionFixtures.principal()
        }
        #expect(outcome.removedIds == [saved.id])
        #expect(store.persistence.loadConnections().map(\.id) == [saved.id])
        #expect(store.persistence.invitedJournal.floors[record.account] == removal.floor)
    }
}
