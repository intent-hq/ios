import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    nonisolated private struct LocalTLSTunnel: TunnelSession {
        let localPort: Int

        func close() async {}
    }

    nonisolated private struct LocalTLSDialer: TunnelDialing {
        let port: Int

        func open(tcAddress _: String, remotePort _: Int) async -> any TunnelSession { LocalTLSTunnel(localPort: port) }
    }

    @Test @MainActor func certificatePinSpellingsUseTheSameValidatedDigest() {
        let colon = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        let compact = colon.replacingOccurrences(of: ":", with: "")
        #expect(WebSocketConnection.fingerprintMatches(colon, pinned: compact.uppercased()))
        #expect(WebSocketConnection.fingerprintMatches(compact, pinned: colon))
        #expect(!WebSocketConnection.fingerprintMatches("ab:cd", pinned: "ab:cd"))
        #expect(!WebSocketConnection.fingerprintMatches(colon, pinned: InvitedSessionFixtures.pin))
    }

    @Test(arguments: [false, true]) @MainActor func canonicalInvitedPinImportsAndReconnectsThroughRealTLS(tunnel: Bool) async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        defer { server.stop() }
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        let cloud = MemorySyncedKeychain()
        let store = try InvitedSessionFixtures.Store(cloud)
        defer { store.close() }
        let colon = ManualTokenEntryViewTests.fixtureIdentityFingerprint
        let compact = colon.replacingOccurrences(of: ":", with: "")
        var object = try InvitedSessionFixtures.session().object
        object["fingerprint"] = compact
        object["host"] = "127.0.0.1"
        object["hosts"] = tunnel ? [String]() : ["127.0.0.1"]
        object["port"] = server.port
        object["tcAddress"] = tunnel ? "tc-test-forwarder" : NSNull()
        object["tcUpdatedAt"] = tunnel ? 100 : NSNull()
        let key = try InvitedSyncKey.session(fingerprint: compact, principalId: "B")
        let record = try #require(InvitedSyncRecord.parse(account: key, data: JSONSerialization.data(withJSONObject: object)))
        cloud.items[key] = record.data
        let manager = ConnectionManager(persistence: store.persistence)
        manager.tunnelDialer = LocalTLSDialer(port: server.port)
        defer { manager.disconnect() }
        _ = await store.persistence.refreshInvitedSessions { candidate in
            defer { manager.disconnect() }
            try await Self.connect(candidate, through: manager, pin: candidate.server.certFingerprint)
            return try await manager.confirmedPrincipal()
        }
        let saved = try #require(store.relaunch().loadConnections().first)
        #expect(saved.principal?.id == "B")
        try await Self.connect(saved, through: manager, pin: saved.server.certFingerprint)
        #expect(manager.currentPrincipal?.id == "B")
        manager.disconnect()
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: saved.token, certFingerprint: colon)
        #expect(manager.currentPrincipal?.id == "B")
        manager.disconnect()
        do {
            try await Self.connect(saved, through: manager, pin: InvitedSessionFixtures.pin)
            Issue.record("The real TLS transport accepted a different certificate pin")
        } catch {
            #expect(manager.currentPrincipal == nil)
        }
    }

    @MainActor private static func connect(_ record: StoredConnection, through manager: ConnectionManager, pin: String?) async throws {
        try await manager.connect(
            hosts: record.server.hosts,
            port: record.server.port,
            token: record.token,
            certFingerprint: pin,
            tcAddress: record.server.tcAddress
        )
    }
}
