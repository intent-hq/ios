import Foundation
@testable import Intent
import Testing

@MainActor struct PersonalPairingPermissionsTests {
    @Test(arguments: [ConnectionPrincipal.HostRole.member, .owner])
    func workspaceDraftSurvivesRecoveryButCannotSubmitUntilAuthorityReturns(role: ConnectionPrincipal.HostRole) {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: WorkspaceStore(connectionManager: connection), connection: connection, persistence: .ephemeral())
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: role)
        connection.connectionState = .connected
        #expect(coordinator.canCreateWorkspace)
        #expect(!coordinator.shouldDismissWorkspaceCreation)
        connection.connectionState = .reconnecting(attempt: 1)
        #expect(!coordinator.canCreateWorkspace)
        #expect(!coordinator.shouldDismissWorkspaceCreation)
        connection.currentPrincipal = nil
        #expect(!coordinator.shouldDismissWorkspaceCreation)
        let provider = ProviderInfo(id: "test-provider", authenticated: true)
        #expect(CreateWorkspaceView.isCreateDisabled(
            isCreating: false,
            isLoadingProviders: false,
            providers: [provider],
            selectedProvider: provider,
            allowsCreation: coordinator.canCreateWorkspace
        ))
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: role)
        connection.connectionState = .connected
        #expect(coordinator.canCreateWorkspace)
        #expect(!coordinator.shouldDismissWorkspaceCreation)
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: .guest)
        #expect(!coordinator.canCreateWorkspace)
        #expect(coordinator.shouldDismissWorkspaceCreation)
    }

    @Test func revokedOrInvalidatedAuthorityStillDismissesWorkspaceDraft() {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: WorkspaceStore(connectionManager: connection), connection: connection, persistence: .ephemeral())
        connection.connectionState = .connected
        connection.currentPrincipal = nil
        #expect(coordinator.shouldDismissWorkspaceCreation)
        #expect(!coordinator.canCreateWorkspace)
        connection.connectionState = .disconnected
        #expect(coordinator.shouldDismissWorkspaceCreation)
        #expect(!coordinator.canCreateWorkspace)
    }

    @Test func controlsRequireLiveAuthorityAndFollowRoleChanges() {
        let connection = FakeConnectionManager()
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: connection),
            connection: connection,
            persistence: .ephemeral()
        )
        connection.connectionState = .connected
        for (role, create, assistant) in [(ConnectionPrincipal.HostRole.guest, false, false), (.member, true, false), (.owner, true, true)] {
            connection.currentPrincipal = InvitedSessionFixtures.principal(role: role)
            #expect(coordinator.canCreateWorkspace == create)
            #expect(coordinator.canUseAssistant == assistant)
        }
        connection.currentPrincipal = nil
        #expect(!coordinator.canCreateWorkspace)
        #expect(!coordinator.canUseAssistant)
        connection.currentPrincipal = InvitedSessionFixtures.principal(role: .owner)
        connection.connectionState = .disconnected
        #expect(!coordinator.canCreateWorkspace)
        #expect(!coordinator.canUseAssistant)
    }

    @Test func invitedBackfillRetainsOriginalClockAndCannotBeatRemoval() throws {
        let cloud = MemorySyncedKeychain()
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        var saved = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        saved.principal = InvitedSessionFixtures.principal()
        saved.invitedSyncPayload = nil
        store.persistence.backfillInvited(&saved)
        #expect(PersistenceManager.invitedRecord(saved)?.pairedAt == 100)
        #expect(store.persistence.upsertConnectionWithOutcome(saved).persisted)
        let removal = try InvitedSessionFixtures.removal()
        var journal = store.persistence.invitedJournal
        journal.observe([removal])
        store.persistence.invitedJournal = journal
        let manager = ConnectionManager(persistence: store.persistence)
        #expect(throws: ConnectionPrincipal.AdmissionError.self) {
            try manager.validateIdentity(InvitedSessionFixtures.principal(), token: saved.token, fingerprint: saved.server.certFingerprint)
        }
    }
}
