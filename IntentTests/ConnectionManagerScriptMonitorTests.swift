import Combine
import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func scriptCapabilitiesComeFromAdmissionAndResetOnReconnect() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        try server.setHello(ScriptMonitorCapabilitiesTests.hello())
        var connectedSupport: [Bool] = []
        let observation = manager.connectionStatePublisher.sink { state in
            if state == .connected { connectedSupport.append(manager.capabilities.supportsScriptMonitors) }
        }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "test-token")
        #expect(connectedSupport == [true])
        #expect(server.helloIDs.count == 1)
        let routing: any ConnectionManagerRouting = manager
        #expect(routing.capabilities.supportsScriptMonitors)
        #expect(routing.capabilities.supportsScriptMonitors)
        #expect(server.helloIDs.count == 1)
        try server.setHello(ScriptMonitorCapabilitiesTests.hello(monitors: 1))
        server.dropConnections()
        try await waitUntil("reconnect replaces script capabilities", timeout: .seconds(5)) {
            connectedSupport.count >= 2
        }
        #expect(connectedSupport.last == false)
        #expect(!routing.capabilities.supportsScriptMonitors)
        manager.disconnect()
        #expect(routing.capabilities == .unknown)
        withExtendedLifetime(observation) {}
    }

    @Test @MainActor func rejectedCandidateCannotOverwriteAdmittedCapabilities() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let working = try await LoopbackWebSocketServer.start()
        let rejected = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); working.stop(); rejected.stop() }
        try working.setHello(ScriptMonitorCapabilitiesTests.hello())
        try await manager.connect(hosts: ["127.0.0.1"], port: working.port, token: "working-token")
        rejected.setPrincipal(["id": "invalid"])
        await #expect(throws: ConnectionPrincipal.AdmissionError.self) {
            try await manager.connect(hosts: ["127.0.0.1"], port: rejected.port, token: "rejected-token")
        }
        #expect(manager.capabilities.supportsScriptMonitors)
        #expect(manager.port == working.port)
    }

    @Test @MainActor func authorityRefreshInvalidatesCapabilitiesAndPreservesConnectionDisable() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        var hello = ScriptMonitorCapabilitiesTests.hello()
        hello["server"] = ["protocolVersion": ProtocolFixtures.currentProtocolVersion, "capabilities": ["hostMembership": 1, "scriptMonitors": 2, "scriptActiveLists": 1]]
        try server.setHello(hello)
        server.setPrincipal(["id": "person", "isAdministrator": false, "hostRole": "guest", "hostMembershipRevision": 1])
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "test-token")
        #expect(manager.capabilities.supportsScriptMonitors)
        manager.disableScriptMonitors()
        server.setPrincipal(["id": "person", "isAdministrator": false, "hostRole": "member", "hostMembershipRevision": 2])
        manager.invalidatePrincipalIfNeeded(method: "events.event", params: ["event": ["type": "host:members-changed", "data": ["revision": 2]]])
        #expect(manager.capabilities == .unknown)
        try await waitUntil("authority refresh completes") { manager.currentPrincipal?.revision == 2 }
        #expect(!manager.capabilities.supportsScriptMonitors)
        #expect(manager.capabilities.scriptMonitorsVersion == 2)
    }
}
