import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func liveAdmissionAndReconnectRefreshRoleBeforeConnected() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        let manager = ConnectionManager(persistence: store.persistence)
        defer { manager.disconnect(); server.stop(); store.close() }
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "guest", "hostMembershipRevision": 1])
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "same-person-test-token")
        #expect(manager.connectionState == .connected)
        #expect(manager.currentPrincipal?.hostRole == .guest)
        #expect(manager.currentPrincipal?.canManageWorkspaces == false)
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 2])
        server.dropConnections()
        try await waitUntil("reconnect has authoritative member identity", timeout: .seconds(5)) {
            manager.connectionState == .connected && manager.currentPrincipal?.hostRole == .member
        }
        #expect(server.helloIDs.count >= 2)
        #expect(Set(server.helloIDs).count == 1)
        #expect(UUID(uuidString: try #require(server.helloIDs.first)) != nil)
    }

    @Test @MainActor func malformedAdmittedPersonCannotReplaceWorkingOwner() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let working = try await LoopbackWebSocketServer.start()
        let malformed = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); working.stop(); malformed.stop() }
        try await manager.connect(hosts: ["127.0.0.1"], port: working.port, token: "old-test-token")
        malformed.setPrincipal(["id": "B", "isAdministrator": false])
        await #expect(throws: ConnectionPrincipal.AdmissionError.self) {
            try await manager.connect(hosts: ["127.0.0.1"], port: malformed.port, token: "bad-test-token")
        }
        #expect(manager.connectionState == .connected)
        #expect(manager.port == working.port)
        #expect(manager.currentPrincipal?.isOwner == true)
        #expect(try await manager.request("system.status") is [String: Any])
    }

    @Test @MainActor func membershipEventInvalidatesBeforeRefreshingAndFencesOlderRevision() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "guest", "hostMembershipRevision": 1])
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "test-token")
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 3])
        func event(_ revision: Int) -> [String: Any] {
            ["event": ["type": "host:members-changed", "data": ["revision": revision]]]
        }
        manager.invalidatePrincipalIfNeeded(method: "events.event", params: event(3))
        #expect(manager.currentPrincipal == nil)
        manager.invalidatePrincipalIfNeeded(method: "events.event", params: event(2))
        #expect(manager.pendingAuthorityRevision == 3)
        try await waitUntil("member authority refreshed") { manager.currentPrincipal?.revision == 3 }
        #expect(manager.currentPrincipal?.hostRole == .member)
        manager.disconnect()
        #expect(manager.currentPrincipal == nil)
    }
}
