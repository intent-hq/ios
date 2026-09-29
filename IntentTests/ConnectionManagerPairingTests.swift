import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    // MARK: - Pairing over a live connection (monorepo#4185)

    /// A loopback port with nothing listening on it, so connections are
    /// refused fast and deterministically.
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

    /// Regression for monorepo#4185: a pairing attempt (QR / manual token /
    /// intent:// link all funnel into `connect()`) that fails while a live
    /// connection is active must NOT strand the app in `.connecting` on a
    /// dead socket — the existing connection keeps serving.
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

        // The live connection was never torn down: state and target are
        // untouched, and the socket still serves a round-trip.
        #expect(manager.connectionState == .connected)
        #expect(manager.port == server.port)
        #expect(manager.token == "live-token")
        let result = try await manager.request("system.status")
        #expect(result is [String: Any])
    }

    /// A failed pairing attempt over a live connection must leave the live
    /// connection's `certMismatches` bookkeeping untouched: the entry-point
    /// reset (different target) must not wipe it, and mismatches observed by
    /// the failed race must not stick to the preserved connection.
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

    /// The success side of the same flow: pairing over a live connection
    /// adopts the new target only once the replacement socket is
    /// established, and the new connection serves round-trips.
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

    /// A tunnel dialer that reports a certificate mismatch only once the test
    /// releases it — `TestGate.wait()` ignores the race's loser cancellation —
    /// so a direct candidate wins first and the mismatch is reported by the
    /// background drain.
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

    /// A preserving connect() retires the old connection — advancing the
    /// connection generation — only AFTER its race is won. A slower losing
    /// candidate's certificate mismatch, reported by the background drain,
    /// must still reach `certMismatches`: the race was not superseded. The
    /// time limit turns a connect() that waits on the gated loser into a
    /// failure instead of a hang: its cancellation of the test opens the gate.
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

        // The direct candidate has won and connect() returned; only now does
        // the losing tunnel candidate report its mismatch.
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

    /// Two overlapping pairing attempts over a live connection: the OLDER
    /// attempt completing first must not install its target and supersede
    /// the newer one. Preserving connects don't tear down (and so don't
    /// advance the generation) up front, so ordering is carried by the
    /// connect-attempt counter: the older attempt is superseded, the newer
    /// one adopts its target.
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

        // Both attempts hang in their WS handshake until their server opens;
        // a gated server counts the socket as accepted while holding it back.
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

        // The older attempt completes its handshake FIRST — it must be
        // superseded rather than install token-old and kill the newer one.
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

    /// A failed pairing attempt while the manager is reconnecting must keep
    /// the reconnect loop (and its target) alive instead of cancelling it
    /// and stranding the app in `.connecting`.
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

        // Kill the live socket so the manager enters its reconnect loop.
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

        // Still recovering toward the ORIGINAL target — not stuck in
        // .connecting on the failed pairing target.
        guard case .reconnecting = manager.connectionState else {
            Issue.record("expected .reconnecting, got \(manager.connectionState)")
            return
        }
        #expect(manager.port == livePort)
        #expect(manager.token == "live-token")
    }
}
