import Foundation
@testable import Intent
import Testing

@MainActor struct PairingAuthorityRaceTests {
    @Test func forgettingWhileStatusIsPendingCannotBecomeANewPairingIntent() async throws {
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        defer { store.close() }
        var previous = try #require(PersistenceManager.connection(fromInvited: InvitedSessionFixtures.session()))
        previous.principal = InvitedSessionFixtures.principal()
        #expect(store.persistence.saveConnectionsLocked([previous]))
        let fake = FakeConnectionManager()
        fake.responseMap["client.hello"] = ["server": ["capabilities": ["hostMembership": 1]]]
        fake.responseMap["principal.me"] = ["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1]
        fake.pendingMethods = ["system.status"]
        let payload = PairingPayload(hosts: previous.server.hosts, port: 443, token: previous.token, certFingerprint: InvitedSessionFixtures.pin, tcAddress: nil)
        let pairing = Task {
            try await PairingFlow.connect(payload: payload, certFingerprint: InvitedSessionFixtures.pin, connectionManager: fake, persistence: store.persistence)
        }
        try await fake.waitForPendingRequests("system.status")
        #expect(store.persistence.deleteConnection(id: previous.id))
        let journal = store.persistence.invitedJournal
        fake.resolvePending("system.status", with: ["hostname": "stale"])
        if case .success = await pairing.result { Issue.record("Forgetting was overwritten by late pairing") }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.clock == journal.clock)
        #expect(store.persistence.invitedJournal.removals == journal.removals)
        #expect(fake.connectionState == .disconnected)
    }

    @Test(arguments: [false, true], [false, true])
    func staleStatusCompletionCannotSaveOrCloseNewerConnection(superseded: Bool, manual: Bool) async throws {
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        defer { store.close() }
        let fake = FakeConnectionManager()
        fake.responseMap["client.hello"] = ["server": ["capabilities": ["hostMembership": 1]]]
        fake.responseMap["principal.me"] = ["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1]
        fake.pendingMethods = ["system.status"]
        let payload = PairingPayload(hosts: ["old.example"], port: 443, token: "B-token", certFingerprint: InvitedSessionFixtures.pin, tcAddress: nil)
        let pairing = Task {
            if manual {
                return try await ManualTokenEntryView.connectAndSave(
                    input: .direct(host: "old.example"),
                    port: 443,
                    fingerprint: InvitedSessionFixtures.pin,
                    token: payload.token,
                    connection: fake,
                    persistence: store.persistence
                )
            }
            return try await PairingFlow.connect(payload: payload, certFingerprint: InvitedSessionFixtures.pin, connectionManager: fake, persistence: store.persistence)
        }
        try await fake.waitForPendingRequests("system.status")
        if superseded {
            try fake.connect(hosts: ["new.example"], port: 443, token: "C-token", certFingerprint: InvitedSessionFixtures.pin, tcAddress: nil)
        } else {
            fake.disconnect()
        }
        let disconnects = fake.disconnectCallCount
        fake.resolvePending("system.status", with: ["hostname": "stale-host"])
        let result = await pairing.result
        if case .success = result { Issue.record("A stale pairing completed successfully") }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.clock == 0)
        #expect(fake.disconnectCallCount == disconnects)
        #expect(fake.connectionState == (superseded ? .connected : .disconnected))
    }
}
