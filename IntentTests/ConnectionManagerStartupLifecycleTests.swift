import Combine
import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    nonisolated private struct StartupTunnel: TunnelSession {
        let localPort: Int

        func close() async {}
    }
    nonisolated private struct StartupDialer: TunnelDialing {
        let port: Int

        func open(tcAddress _: String, remotePort _: Int) async -> any TunnelSession { StartupTunnel(localPort: port) }
    }

    @Test(arguments: [false, true], [false, true]) @MainActor
    func startupSecureSavedRoutesRequireFreshAdmission(tunnel: Bool, readyStatus: Bool) async throws {
        let server = try await LoopbackWebSocketServer.start(tlsIdentity: ManualTokenEntryViewTests.fixtureIdentity())
        let persistence = PersistenceManager.ephemeral()
        let manager = ConnectionManager(persistence: persistence)
        defer { manager.disconnect(); server.stop() }
        manager.tunnelDialer = StartupDialer(port: server.port)
        let record = saveStartupRoute(persistence, port: server.port, tunnel: tunnel)
        var connectedCount = 0
        let observation = manager.connectionStatePublisher.sink { if $0 == .connected { connectedCount += 1 } }
        defer { observation.cancel() }
        try server.setStartup(Self.startupSnapshot())
        let connecting = Task {
            try await manager.connect(
                hosts: record.server.hosts,
                port: record.server.port,
                token: record.token,
                certFingerprint: record.server.certFingerprint,
                tcAddress: record.server.tcAddress
            )
        }
        defer { connecting.cancel() }
        try await waitUntil("secure startup shown") { manager.startupState != nil }
        #expect(connectedCount == 0)
        #expect(manager.admission == nil)
        #expect(persistence.loadConnections().first?.token == "saved-owner")
        #expect(Set(server.methods).isSubset(of: ["client.hello", "system.startupStatus"]))
        if readyStatus {
            try server.setStartup(Self.startupSnapshot(phase: "ready"))
        } else {
            server.clearStartup()
            server.dropConnections()
        }
        try await connecting.value
        #expect(connectedCount == 1)
        #expect(server.acceptedCount == 2)
        #expect(manager.startupState == nil)
        #expect(manager.currentPrincipal?.isOwner == true)
        #expect((manager.activeTunnel != nil) == tunnel)
        // A subsequent daemon restart follows the same admission path.
        try server.setStartup(Self.startupSnapshot(phase: "finalizing", attempt: "boot-b"))
        server.dropConnections()
        try await waitUntil("reconnect finalization", timeout: .seconds(10)) {
            if case .starting(let snapshot) = manager.startupState { return snapshot?.phase == .finalizing }
            return false
        }
        #expect(connectedCount == 1)
        #expect(manager.currentPrincipal == nil)
        try server.setStartup(Self.startupSnapshot(phase: "ready", attempt: "boot-b"))
        try await waitUntil("reconnected after fresh hello", timeout: .seconds(10)) { manager.connectionState == .connected }
        #expect(connectedCount == 2)
        #expect(server.acceptedCount == 4)
    }

    @MainActor private func saveStartupRoute(_ persistence: PersistenceManager, port: Int, tunnel: Bool) -> StoredConnection {
        persistence.upsertConnection(StoredConnection(
            server: PairedServer(
                hosts: tunnel ? [] : ["127.0.0.1"],
                port: port,
                name: "Startup host",
                pairedAt: Date(),
                certFingerprint: ManualTokenEntryViewTests.fixtureIdentityFingerprint,
                tcAddress: tunnel ? "saved-owner-tailcat" : nil
            ),
            token: "saved-owner",
            displayName: "Startup host"
        ))
    }

    @Test @MainActor func startupBackgroundCancelsPollingAndResumesWithFreshHello() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        try server.setStartup(Self.startupSnapshot())
        server.holdStartupStatus()
        let connecting = Task { try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner") }
        defer { connecting.cancel() }
        try await waitUntil("poll in flight") { server.heldStartupCount == 1 }
        manager.setStartupSuspended(true)
        try await waitUntil("bootstrap seat retired") { manager.startupCandidate == nil }
        #expect(manager.startupState == .unavailable)
        let requests = server.methods.count
        try await Task.sleep(for: .milliseconds(1200))
        #expect(server.methods.count == requests)
        #expect(server.acceptedCount == 1)
        server.clearStartup()
        server.releaseStartupStatus()
        manager.setStartupSuspended(false)
        try await connecting.value
        #expect(server.acceptedCount == 2)
        #expect(manager.connectionState == .connected)
    }

    @Test @MainActor func startupFailureSurvivesBackgroundingAndRetryAdmitsFreshly() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let server = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); server.stop() }
        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "owner")
        try server.setStartup(Self.startupSnapshot(phase: "failed"))
        server.dropConnections()
        try await waitUntil("reconnect reports failure", timeout: .seconds(10)) { manager.startupState == .failed }
        manager.setStartupSuspended(true)
        #expect(manager.startupState == .failed)
        manager.setStartupSuspended(false)
        #expect(manager.startupState == .failed)
        let accepted = server.acceptedCount
        server.clearStartup()
        manager.retryConnection()
        try await waitUntil("retry reconnects", timeout: .seconds(10)) { manager.connectionState == .connected }
        #expect(manager.startupState == nil)
        #expect(server.acceptedCount == accepted + 1)
    }

    @Test @MainActor func startupLateReplyCannotReplaceDifferentBackendOrReviveDisconnect() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let old = try await LoopbackWebSocketServer.start()
        let replacement = try await LoopbackWebSocketServer.start()
        let manager = ConnectionManager(persistence: .ephemeral())
        defer { manager.disconnect(); old.stop(); replacement.stop() }
        try old.setStartup(Self.startupSnapshot())
        old.holdStartupStatus()
        let first = Task { try await manager.connect(hosts: ["127.0.0.1"], port: old.port, token: "old") }
        defer { first.cancel() }
        try await waitUntil("old status held") { old.heldStartupCount == 1 }
        try await manager.connect(hosts: ["127.0.0.1"], port: replacement.port, token: "new")
        old.releaseStartupStatus()
        _ = await first.result
        #expect(manager.port == replacement.port)
        #expect(manager.connectionState == .connected)
        #expect(manager.startupState == nil)
        manager.disconnect()
        #expect(manager.currentPrincipal == nil)
        #expect(manager.startupState == nil)
        #expect(manager.startupCandidate == nil)
    }
}
