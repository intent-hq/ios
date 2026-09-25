import Foundation
import Testing

@testable import Intent

extension ConnectionManagerTests {
    nonisolated struct ImportedRouteDialer: TunnelDialing {
        let localPort: Int
        let expectedAddress: String

        func open(tcAddress: String, remotePort _: Int) async throws -> any TunnelSession {
            guard tcAddress == expectedAddress else { throw CocoaError(.coderReadCorrupt) }
            return PathTunnelSession(localPort: localPort)
        }
    }

    @Test @MainActor func importedBackendConnectsThroughTunnelWhenLANRefuses() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await RecoveryWebSocketServer.start()
        let manager = ConnectionManager.shared
        let originalDialer = manager.tunnelDialer
        let originalMonitor = manager.makePathMonitor
        manager.tunnelDialer = ImportedRouteDialer(localPort: server.port, expectedAddress: BackendSyncFixtures.route)
        manager.makePathMonitor = { FakePathMonitor() }
        defer {
            manager.disconnect()
            manager.tunnelDialer = originalDialer
            manager.makePathMonitor = originalMonitor
            server.stop()
        }
        var record = SyncedBackendConnectionMergeTests().record(host: "127.0.0.2", port: server.port)
        record.tcAddress = BackendSyncFixtures.route
        let imported = try #require(SyncedBackendConnectionMerge.merge(records: [record], into: []).connections.first)
        #expect(imported.server.certFingerprint == record.fingerprint)
        // The fake tunnel terminates at a plaintext loopback fixture. The
        // import's pin is asserted above; production dials keep that pin.
        try await manager.connect(
            hosts: imported.server.hosts, port: imported.server.port, token: imported.token,
            certFingerprint: nil, tcAddress: imported.server.tcAddress
        )
        #expect(manager.connectionState == .connected)
        #expect(manager.tcAddress == BackendSyncFixtures.route)
    }
}
