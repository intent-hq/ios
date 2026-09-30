import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test(arguments: [false, true], [false, true]) @MainActor
    func unsuccessfulPairingRetiresItsOwnAutomaticReconnect(manual: Bool, cancelled: Bool) async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        server.holdHostStatus()
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        let manager = ConnectionManager(persistence: store.persistence)
        defer { server.releaseHostStatus(); server.open(); manager.disconnect(); server.stop(); store.close() }
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        let pairing = Task {
            if manual {
                return try await ManualTokenEntryView.connectAndSave(
                    input: .direct(host: "127.0.0.1"),
                    port: server.port,
                    fingerprint: pin,
                    token: "unsaved-T1",
                    connection: manager,
                    persistence: store.persistence
                )
            }
            let payload = PairingPayload(hosts: ["127.0.0.1"], port: server.port, token: "unsaved-T1", certFingerprint: pin, tcAddress: nil)
            return try await PairingFlow.connect(payload: payload, certFingerprint: pin, connectionManager: manager, persistence: store.persistence)
        }
        try await waitUntil("pairing and post-connect host status are suspended", timeout: .seconds(5)) { server.heldStatusCount >= 2 }
        server.holdNewConnections()
        if cancelled { pairing.cancel() }
        server.dropConnections()
        if case .success = await pairing.result { Issue.record("A lost pairing was saved") }
        #expect(manager.reconnectTask == nil)
        #expect(manager.connectionState == .disconnected)
        #expect(store.persistence.loadConnections().isEmpty)
        #expect(store.persistence.invitedJournal.clock == 0)
        server.releaseHostStatus()
        server.open()
        try await expectNever("an unsaved pairing adopted a replacement socket", within: .milliseconds(500)) {
            manager.admission != nil || manager.connectionState == .connected
        }
    }
}
