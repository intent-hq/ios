import Foundation
@testable import Intent
import os
import Testing

extension ConnectionManagerTests {
    nonisolated private final class RouteRefreshDialer: TunnelDialing, Sendable {
        let port: Int
        private let routes = OSAllocatedUnfairLock(initialState: [String]())
        var opened: [String] { routes.withLock { $0 } }

        init(port: Int) { self.port = port }
        func reset() { routes.withLock { $0 = [] } }
        func open(tcAddress: String, remotePort _: Int) async -> any TunnelSession {
            routes.withLock { $0.append(tcAddress) }
            return PathTunnelSession(localPort: port)
        }
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func delayedSocketRouteCannotOverwriteImportedReconnectRoute(clear: Bool, rotateToken: Bool) async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        server.setPrincipal(["id": "B", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 1])
        try server.setSystemStatus(["localIps": ["127.0.0.2"], "tcAddress": "tcOld"])
        server.holdSystemStatus()
        let cloud = MemorySyncedKeychain()
        let store = try InvitedSessionFixtures.Store(cloud)
        let manager = ConnectionManager(persistence: store.persistence)
        let dialer = RouteRefreshDialer(port: server.port)
        manager.tunnelDialer = dialer
        defer { server.releaseSystemStatus(); manager.disconnect(); server.stop(); store.close() }
        let initial = try Self.routeRefreshRecord(port: server.port, token: "T1", route: "tcOld", clock: 100)
        cloud.items[initial.account] = initial.data
        _ = await store.persistence.refreshInvitedSessions { _ in InvitedSessionFixtures.principal() }
        let saved = try #require(store.persistence.loadConnections().first)
        try await manager.connect(hosts: saved.server.hosts, port: server.port, token: saved.token, certFingerprint: saved.server.certFingerprint, tcAddress: saved.server.tcAddress)
        let originalAdmission = try #require(manager.admission)
        let refresh = Task { await manager.refreshHostRoutes() }
        try await waitUntil("old system status replies are suspended", timeout: .seconds(5)) { server.heldSystemStatusCount >= 2 }
        let token = rotateToken ? "T2" : "T1"
        let route: String? = clear ? nil : "tcNew"
        let replacement = try Self.routeRefreshRecord(port: server.port, token: token, route: route, clock: 200)
        cloud.items[replacement.account] = replacement.data
        let coordinator = AppCoordinator(
            workspaceStore: WorkspaceStore(connectionManager: manager),
            connection: manager,
            backendID: BackendID(saved.id),
            persistence: store.persistence,
            sessionRegistry: BackendSessionRegistry()
        )
        coordinator.refreshInvitedConnections { _ in InvitedSessionFixtures.principal() }
        await coordinator.invitedRefreshTask?.value
        #expect(manager.tcAddress == route)
        #expect(manager.token == token)
        #expect(manager.admission == originalAdmission)
        try server.setSystemStatus(["localIps": [String]()])
        server.releaseSystemStatus()
        await refresh.value
        #expect(manager.tcAddress == route)
        #expect(!manager.hosts.contains("127.0.0.2"))
        #expect(store.persistence.loadConnections().first?.server.tcAddress == route)
        dialer.reset()
        server.dropConnections()
        try await waitUntil("fresh socket uses imported credentials", timeout: .seconds(5)) {
            manager.connectionState == .connected && manager.admission?.id != originalAdmission.id
        }
        #expect(manager.admission?.token == token)
        #expect(manager.tcAddress == route)
        #expect(dialer.opened == (clear ? [] : ["tcNew"]))
    }

    @Test @MainActor func currentOwnerStatusStillRefreshesItsReconnectRoutes() async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        try server.setSystemStatus(["localIps": ["127.0.0.2"], "tcAddress": "tcCurrent"])
        let store = try InvitedSessionFixtures.Store(MemorySyncedKeychain())
        let manager = ConnectionManager(persistence: store.persistence)
        defer { manager.disconnect(); server.stop(); store.close() }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner-token", certFingerprint: ManualTokenEntryViewTests.fixtureIdentityFingerprint)
        await manager.refreshHostRoutes()
        #expect(manager.tcAddress == "tcCurrent")
        #expect(manager.hosts == ["127.0.0.1", "127.0.0.2"])
        #expect(manager.currentPrincipal?.isOwner == true)
    }

    @MainActor private static func routeRefreshRecord(port: Int, token: String, route: String?, clock: Double) throws -> InvitedSyncRecord {
        let pin = ManualTokenEntryViewTests.fixtureIdentityFingerprint.replacingOccurrences(of: ":", with: "")
        var object = try InvitedSessionFixtures.session().object
        object["fingerprint"] = pin
        object["port"] = port
        object["host"] = "127.0.0.1"
        object["hosts"] = route == nil ? ["127.0.0.1"] : []
        object["token"] = token
        object["pairedAt"] = token == "T1" ? 100 : clock
        object["updatedAt"] = clock
        object["tcAddress"] = route.map { $0 as Any } ?? NSNull()
        object["tcUpdatedAt"] = clock
        let key = try InvitedSyncKey.session(fingerprint: pin, principalId: "B")
        return try #require(InvitedSyncRecord.parse(account: key, data: JSONSerialization.data(withJSONObject: object)))
    }
}
