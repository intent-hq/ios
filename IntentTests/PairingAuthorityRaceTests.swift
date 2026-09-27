import Foundation
@testable import Intent
import Testing

@MainActor struct PairingAuthorityRaceTests {
    @Test(arguments: [false, true]) func staleStatusCompletionCannotSaveOrCloseNewerConnection(superseded: Bool) async throws {
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        defer { store.close() }
        let fake = FakeConnectionManager()
        fake.responseMap["client.hello"] = ["server": ["capabilities": ["hostMembership": 1]]]
        fake.responseMap["principal.me"] = ["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1]
        fake.pendingMethods = ["host.status"]
        let payload = PairingPayload(hosts: ["old.example"], port: 443, token: "B-token", certFingerprint: InvitedSessionFixtures.pin, tcAddress: nil)
        let pairing = Task {
            try await PairingFlow.connect(payload: payload, certFingerprint: InvitedSessionFixtures.pin, connectionManager: fake, persistence: store.persistence)
        }
        try await fake.waitForPendingRequests("host.status")
        if superseded {
            try await fake.connect(hosts: ["new.example"], port: 443, token: "C-token", certFingerprint: InvitedSessionFixtures.pin, tcAddress: nil)
        } else {
            fake.disconnect()
        }
        let disconnects = fake.disconnectCallCount
        fake.resolvePending("host.status", with: ["hostname": "stale-host"])
        let result = await pairing.result
        if case .success = result { Issue.record("A stale pairing completed successfully") }
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.clock == 0)
        #expect(fake.disconnectCallCount == disconnects)
        #expect(fake.connectionState == (superseded ? .connected : .disconnected))
    }
}
