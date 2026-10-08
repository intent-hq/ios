import Foundation
@testable import Intent
import Security
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func classifiedLegacyRevocationSurvivesAnUnavailableCloudRegistry() async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        let cloud = MemorySyncedKeychain()
        cloud.readFailure = errSecInteractionNotAllowed
        let store = try InvitedSessionFixtures.Store(cloud)
        let manager = ConnectionManager(persistence: store.persistence)
        defer { manager.disconnect(); server.stop(); store.close() }
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        let legacy = StoredConnection(
            server: PairedServer(hosts: ["127.0.0.1"], port: server.port, name: "legacy", pairedAt: Date(), certFingerprint: pin), token: "legacy-token"
        )
        #expect(store.persistence.saveConnectionsLocked([legacy]))
        try await manager.connect(hosts: legacy.server.hosts, port: server.port, token: legacy.token, certFingerprint: pin)
        let classified = try #require(store.persistence.loadConnections().first)
        #expect(classified.principal?.id == "B")
        #expect(classified.invitedSyncPayload == nil)
        try server.emitRemoval(of: "B")
        try await waitUntil("legacy socket revocation") { manager.connectionState == .disconnected }
        let journal = store.relaunch().invitedJournal
        #expect(journal.removals.count == 1)
        cloud.readFailure = nil
        _ = await store.persistence.refreshInvitedSessions { _ in
            Issue.record("Revoked legacy credentials were authenticated again")
            return InvitedSessionFixtures.principal()
        }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.removals == journal.removals)
        for (key, data) in journal.removals { #expect(cloud.items[key] == data) }
    }

    @Test @MainActor func removalOnTheWirePreventsDelayedPairingSave() async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        server.holdSystemStatus()
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        let manager = ConnectionManager(persistence: store.persistence)
        defer { server.releaseSystemStatus(); manager.disconnect(); server.stop(); store.close() }
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        let payload = PairingPayload(hosts: ["127.0.0.1"], port: server.port, token: "B-token", certFingerprint: pin, tcAddress: nil)
        let pairing = Task { try await PairingFlow.connect(payload: payload, certFingerprint: pin, connectionManager: manager, persistence: store.persistence) }
        try await waitUntil("both post-connect and pairing status requests suspended", timeout: .seconds(5)) { server.heldSystemStatusCount >= 2 }
        try server.emitRemoval(of: "B")
        try await waitUntil("membership removal disconnected the admitted socket") { manager.connectionState == .disconnected }
        server.releaseSystemStatus()
        if case .success = await pairing.result { Issue.record("Revoked pairing was saved") }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.clock == 0)
    }

    @Test(arguments: [false, true]) @MainActor func reconnectCacheRotationKeepsOldSocketRevocationSeparate(revokeOld: Bool) async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        let manager = ConnectionManager(persistence: store.persistence)
        defer { manager.disconnect(); server.stop(); store.close() }
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "old-token", certFingerprint: pin)
        let oldAdmission = try #require(manager.admission)
        var replacement = StoredConnection(
            server: PairedServer(hosts: ["127.0.0.1"], port: server.port, name: "test", pairedAt: Date(), certFingerprint: pin), token: "new-token"
        )
        replacement.principal = InvitedSessionFixtures.principal()
        try store.persistence.prepareInvitedPairing(&replacement)
        #expect(store.persistence.upsertConnectionWithOutcome(replacement).persisted)
        manager.updateCachedCredentials(hosts: ["127.0.0.1"], port: server.port, token: "new-token", certFingerprint: pin, tcAddress: nil)
        #expect(manager.admission == oldAdmission)
        if revokeOld {
            try server.emitRemoval(of: "B")
            try await waitUntil("old socket is disconnected") { manager.connectionState == .disconnected }
            #expect(store.persistence.invitedJournal.removals.isEmpty)
            #expect(store.persistence.loadConnections().first?.token == "new-token")
        } else {
            server.dropConnections()
            try await waitUntil("new credential has completed fresh socket admission", timeout: .seconds(5)) {
                manager.connectionState == .connected && manager.admission?.token == "new-token"
            }
            #expect(manager.admission?.id != oldAdmission.id)
            #expect(server.helloIDs.count >= 2)
        }
    }
}
