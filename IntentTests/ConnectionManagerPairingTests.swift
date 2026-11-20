import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    private static func unusedLoopbackPort() async throws -> Int {
        let server = try await LoopbackWebSocketServer.start()
        let port = server.port
        server.stop()
        return port
    }

    @Test @MainActor func pinlessConnectNeverOpensPlaintextSocket() async throws {
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }
        #expect(!WebSocketConnection.plaintextLoopbackOverrideActive)
        let stateBefore = manager.connectionState

        for fingerprint in [nil, "", "  "] as [String?] {
            do {
                try await manager.connect(
                    hosts: ["127.0.0.1"],
                    port: server.port,
                    token: "secret-token",
                    certFingerprint: fingerprint
                )
                Issue.record("expected connect() to refuse a pin-less record")
            } catch let error as WebSocketTransportError {
                #expect(error.isMissingCertificatePin)
                #expect(ConnectionFailureView.isCertificateMismatchMessage(error.localizedDescription))
            } catch {
                Issue.record("unexpected error: \(error)")
            }
        }

        let noDialWindowMilliseconds = 200
        try await expectNever("socket dial for a pin-less record", within: .milliseconds(noDialWindowMilliseconds)) {
            server.acceptedCount != 0
                || manager.connectionState != stateBefore
                || manager.token == "secret-token"
        }
    }

    @Test @MainActor func failedPairingOverLiveConnectionKeepsItServing() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: server.port,
            token: "live-token"
        )
        #expect(manager.connectionState == .connected)

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: deadPort,
                token: "new-token"
            )
        }

        #expect(manager.connectionState == .connected)
        #expect(manager.port == server.port)
        #expect(manager.token == "live-token")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    @Test @MainActor func failedPairingOverLiveConnectionKeepsCertMismatches() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: server.port,
            token: "live-token"
        )
        #expect(manager.connectionState == .connected)
        let liveMismatches = [HostCertMismatch(host: "127.0.0.1", fingerprint: "aa:bb")]
        manager.certMismatches = liveMismatches

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: deadPort,
                token: "new-token"
            )
        }

        #expect(manager.certMismatches == liveMismatches)
    }
}

extension ConnectionManagerTests {
    @Test @MainActor func successfulPairingOverLiveConnectionAdoptsNewTarget() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let serverA = try await LoopbackWebSocketServer.start()
        let serverB = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: serverA.port,
            token: "token-a"
        )
        #expect(manager.connectionState == .connected)

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: serverB.port,
            token: "token-b"
        )

        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        #expect(manager.token == "token-b")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    nonisolated private struct GatedMismatchTunnelDialer: TunnelDialing {
        let fingerprint: String
        let release: TestGate

        func open(tcAddress _: String, remotePort _: Int) async throws -> any TunnelSession {
            await release.wait()
            throw WebSocketTransportError.certificateMismatch(
                host: ConnectionManager.tunnelCandidateLabel,
                fingerprint: fingerprint
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    @MainActor func successfulPairingOverLiveConnectionKeepsLateLoserMismatch() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let serverA = try await LoopbackWebSocketServer.start()
        let serverB = try await LoopbackWebSocketServer.start()
        let originalDialer = manager.tunnelDialer
        defer {
            manager.tunnelDialer = originalDialer
            manager.disconnect()
            serverA.stop()
            serverB.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: serverA.port,
            token: "token-a"
        )
        #expect(manager.connectionState == .connected)

        let loserRelease = TestGate()
        manager.tunnelDialer = GatedMismatchTunnelDialer(fingerprint: "cc:dd", release: loserRelease)
        try await loserRelease.opening {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: serverB.port,
                token: "token-b",
                tcAddress: "tc-slow"
            )
        }
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        #expect(manager.token == "token-b")

        loserRelease.open()
        let expected = [
            HostCertMismatch(
                host: ConnectionManager.tunnelCandidateLabel,
                fingerprint: "cc:dd"
            )
        ]
        let lateMismatchTimeoutSeconds = 3
        try await waitUntil("late loser mismatch recorded", timeout: .seconds(lateMismatchTimeoutSeconds)) {
            manager.certMismatches == expected
        }
    }

    @Test @MainActor func olderOverlappingPairingAttemptDoesNotWin() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let liveServer = try await LoopbackWebSocketServer.start()
        let olderTarget = try await LoopbackWebSocketServer.start(gated: true)
        let newerTarget = try await LoopbackWebSocketServer.start(gated: true)
        defer {
            manager.disconnect()
            liveServer.stop()
            olderTarget.stop()
            newerTarget.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: liveServer.port,
            token: "live-token"
        )
        #expect(manager.connectionState == .connected)

        let older = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: olderTarget.port,
                token: "token-old"
            )
        }
        try await waitUntil("older attempt to reach its gated handshake") {
            olderTarget.acceptedCount == 1
        }
        let newer = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: newerTarget.port,
                token: "token-new"
            )
        }
        try await waitUntil("newer attempt to reach its gated handshake") {
            newerTarget.acceptedCount == 1
        }

        olderTarget.open()
        await #expect(throws: (any Error).self) { try await older.value }
        #expect(manager.token != "token-old")

        newerTarget.open()
        try await newer.value

        #expect(manager.connectionState == .connected)
        #expect(manager.port == newerTarget.port)
        #expect(manager.token == "token-new")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    @Test @MainActor func failedPairingWhileReconnectingKeepsReconnectLoop() async throws {
        let previous = Self.enablePlaintextLoopback()
        defer { Self.restorePlaintextLoopback(previous) }
        let manager = ConnectionManager.shared
        let server = try await LoopbackWebSocketServer.start()
        defer {
            manager.disconnect()
            server.stop()
        }

        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: server.port,
            token: "live-token"
        )
        #expect(manager.connectionState == .connected)
        let livePort = server.port

        server.stop()
        let reconnectingTimeoutSeconds = 5
        try await waitUntil(
            "manager entering .reconnecting after socket loss",
            timeout: .seconds(reconnectingTimeoutSeconds)
        ) { Self.isReconnecting(manager.connectionState) }

        let deadPort = try await Self.unusedLoopbackPort()
        await #expect(throws: (any Error).self) {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: deadPort,
                token: "new-token"
            )
        }

        guard case .reconnecting = manager.connectionState else {
            Issue.record("expected .reconnecting, got \(manager.connectionState)")
            return
        }
        #expect(manager.port == livePort)
        #expect(manager.token == "live-token")
    }
}
