import Foundation
@testable import Intent
import Testing

@MainActor struct AppCoordinatorInvitedSyncTests {
    @Test func delayedInvitedImportImmediatelyUpdatesSavedConnectionPresentation() async throws {
        let cloud = MemorySyncedKeychain()
        let record = try InvitedSessionFixtures.session()
        cloud.items[record.account] = record.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: connection),
            connection: connection,
            persistence: store.persistence,
            sessionRegistry: BackendSessionRegistry()
        )
        coordinator.currentScreen = .pairing
        let gate = TestGate()
        defer { gate.open() }
        var authenticating = false
        coordinator.refreshInvitedConnections { _ in
            authenticating = true
            await gate.wait()
            return InvitedSessionFixtures.principal()
        }
        try await waitUntil("delayed invited import") { authenticating }
        #expect(!coordinator.pairingShowsSavedConnections)
        #expect(coordinator.savedConnections.isEmpty)
        gate.open()
        await coordinator.invitedRefreshTask?.value
        #expect(coordinator.pairingShowsSavedConnections)
        #expect(coordinator.savedConnections.map(\.token) == [record.token])
    }

    @Test func invitedRotationUpdatesEveryAffectedSessionButKeepsSocketReceipt() async throws {
        let cloud = MemorySyncedKeychain()
        let initial = try InvitedSessionFixtures.session()
        cloud.items[initial.account] = initial.data
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.persistence.loadConnections().first)
        let live = FakeConnectionManager()
        live.currentPrincipal = InvitedSessionFixtures.principal()
        try await live.connect(
            hosts: saved.server.hosts,
            port: saved.server.port,
            token: saved.token,
            certFingerprint: saved.server.certFingerprint,
            tcAddress: nil
        )
        let receipt = live.admission
        let registry = BackendSessionRegistry { id in Self.session(id: id, connection: live, persistence: store.persistence) }
        let id = BackendID(saved.id)
        _ = registry.attach(id)
        defer { registry.detach(id) }
        let unbound = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: unbound),
            connection: unbound,
            persistence: store.persistence,
            sessionRegistry: registry
        )
        let replacement = try InvitedSessionFixtures.session(changes: [
            "token": "B-rotated", "pairedAt": 300, "updatedAt": 300, "tcAddress": "tcNew", "tcUpdatedAt": 300
        ])
        cloud.items[replacement.account] = replacement.data
        coordinator.refreshInvitedConnections { candidate in
            #expect(candidate.token == "B-rotated")
            return InvitedSessionFixtures.principal()
        }
        await coordinator.invitedRefreshTask?.value
        #expect(live.updateCachedCredentialsLog.last?.token == "B-rotated")
        #expect(live.updateCachedCredentialsLog.last?.tcAddress == "tcNew")
        #expect(live.admission == receipt)
        #expect(unbound.updateCachedCredentialsLog.isEmpty)
    }

    static func session(id: BackendID?, connection: FakeConnectionManager, persistence: PersistenceManager) -> BackendSession {
        let workspace = WorkspaceStore(connectionManager: connection)
        let loader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: id,
            connection: connection,
            workspaceStore: workspace,
            coordinatorFactory: { _ in AppCoordinator(workspaceStore: workspace, connection: connection, persistence: persistence) },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: loader,
            attachmentImageLoader: AttachmentImageLoader(connection: connection, fileLoader: loader),
            attentionCueCenter: WorkspaceAttentionCueCenter {}
        )
    }
}
