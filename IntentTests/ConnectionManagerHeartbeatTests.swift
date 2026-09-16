import Foundation
@testable import Intent
import Testing

extension ConnectionManagerTests {
    @Test @MainActor func heartbeatGapBeyondTimeoutProbesInsteadOfDisconnecting() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }

        clock.advance(by: .seconds(120))
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(server.pingsReceived == 1)
        #expect(disconnects.count == .zero)
        #expect(manager.connectionState == .connected)
        #expect(try await manager.request("system.status") is [String: Any])
    }

    @Test @MainActor func unansweredProbeDisconnectsOnce() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start(pongs: .withheld)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        #expect(disconnects.count == .zero)
        #expect(manager.connectionState == .connected)

        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        try await Self.settle(timeout: .seconds(5)) {
            manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(disconnects.count == 1)
        #expect(manager.connectionState == .connected)
    }

    @Test @MainActor func probeOfRetiredGenerationIsIgnored() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let serverA = try await RecoveryWebSocketServer.start(pongs: .withheld)
        let serverB = try await RecoveryWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverA.port, token: "a")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverA.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverB.port, token: "b")
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        try await Self.settle {
            serverB.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(serverA.pingsReceived == 1)
        #expect(serverB.pingsReceived == 1)
        #expect(disconnects.count == .zero)
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func latePongOfRetiredGenerationIsIgnored() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let serverA = try await RecoveryWebSocketServer.start(pongs: .replied)
        let serverB = try await RecoveryWebSocketServer.start(pongs: .withheld)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            clock.holdsCancelledSleepers = false
            manager.disconnect()
            clock.releaseHeld(asCompleted: false)
            manager.heartbeatClock = originalClock
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: serverA.port, token: "a")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        clock.holdsCancelledSleepers = true
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverA.pingsReceived == 1
                && clock.heldDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        let retiredHeartbeat = try #require(manager.heartbeatTask)

        try await manager.connect(hosts: ["127.0.0.1"], port: serverB.port, token: "b")
        clock.holdsCancelledSleepers = false
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        clock.releaseHeld(asCompleted: false)
        await retiredHeartbeat.value
        #expect(disconnects.count == .zero)
        #expect(manager.port == serverB.port)

        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            serverB.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatProbeTimeout]
        }
        clock.advance(by: ConnectionManager.heartbeatProbeTimeout)
        try await Self.settle(timeout: .seconds(5)) {
            manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(disconnects.count == 1)
        #expect(serverA.pingsReceived == 1)
        #expect(serverB.pingsReceived == 1)
        #expect(manager.port == serverB.port)
    }

    @Test @MainActor func lateCadenceWakeAfterAutomaticReconnectDoesNotProbe() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            clock.holdsCancelledSleepers = false
            manager.disconnect()
            clock.releaseHeld(asCompleted: false)
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        let retiredHeartbeat = try #require(manager.heartbeatTask)
        clock.holdsCancelledSleepers = true
        server.dropClients()
        try await Self.settle(timeout: .seconds(5)) {
            clock.heldDurations == [ConnectionManager.heartbeatInterval]
                && manager.connectionState == .connected
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        clock.holdsCancelledSleepers = false
        #expect(disconnects.count == 1)
        #expect(server.pingsReceived == 0)

        clock.releaseHeld(asCompleted: true)
        await retiredHeartbeat.value
        #expect(disconnects.count == 1)
        #expect(server.pingsReceived == 0)
        clock.advance(by: ConnectionManager.heartbeatInterval)
        try await Self.settle {
            server.pingsReceived == 1
                && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
        }
        #expect(disconnects.count == 1)
        #expect(manager.connectionState == .connected)
    }

    @Test @MainActor func heartbeatProbesOncePerInterval() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let clock = ManualHeartbeatClock()
        let server = try await RecoveryWebSocketServer.start(pongs: .replied)
        let originalClock = manager.heartbeatClock
        manager.heartbeatClock = clock
        defer {
            manager.disconnect()
            manager.heartbeatClock = originalClock
            server.stop()
        }

        try await manager.connect(hosts: ["127.0.0.1"], port: server.port, token: "token")
        let disconnects = DisconnectCounter(manager)
        try await Self.settle { clock.pendingDurations == [ConnectionManager.heartbeatInterval] }
        for expected in 1...2 {
            clock.advance(by: ConnectionManager.heartbeatInterval)
            try await Self.settle {
                server.pingsReceived == expected
                    && clock.pendingDurations == [ConnectionManager.heartbeatInterval]
            }
        }
        clock.advance(by: ConnectionManager.heartbeatInterval - .seconds(1))
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.pingsReceived == 2)
        clock.advance(by: .seconds(1))
        try await Self.settle { server.pingsReceived == 3 }
        #expect(disconnects.count == .zero)
        #expect(manager.connectionState == .connected)
    }
}
