import Combine
import Foundation
@testable import Intent
import Network
import os
import Testing

extension ConnectionManagerTests {
    // MARK: - Pairing over a live connection (monorepo#4185)

    /// Loopback plain-WS listener with a minimal JSON-RPC responder: any
    /// request carrying an `id` gets an empty-object result; notifications
    /// are ignored. Lets `connect()` tests establish real sockets and prove
    /// a connection still serves round-trips. Nonisolated for the same
    /// reason as ManualTokenEntryViewTests' TLS listener: the handlers run
    /// on the listener queue and must not inherit MainActor isolation.
    nonisolated private struct LoopbackWebSocketServerState {
        var accepted: [NWConnection] = []
        // Connections held back by a gated server: accepted but not
        // started, so the client's WS handshake stays pending until
        // `open()` releases them. Lets tests control which of two
        // racing connect() calls completes first.
        var pendingStart: [NWConnection] = []
        var isOpen: Bool
    }

    nonisolated private final class LoopbackWebSocketServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "ConnectionManagerTests.ws-server")
        // Retain accepted connections for the listener's lifetime (an
        // unreferenced NWConnection deallocates and drops the socket).
        private let state: OSAllocatedUnfairLock<LoopbackWebSocketServerState>

        var port: Int { Int(listener.port?.rawValue ?? 0) }

        private init(listener: NWListener, gated: Bool) {
            self.listener = listener
            self.state = OSAllocatedUnfairLock(
                initialState: LoopbackWebSocketServerState(isOpen: !gated)
            )
        }

        static func start(gated: Bool = false) async throws -> LoopbackWebSocketServer {
            let parameters = NWParameters.tcp
            let wsOptions = NWProtocolWebSocket.Options()
            wsOptions.autoReplyPing = true
            parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
            let server = LoopbackWebSocketServer(
                listener: try NWListener(using: parameters, on: .any),
                gated: gated
            )
            server.listener.newConnectionHandler = { [weak server] connection in
                guard let server else { return }
                let startNow = server.state.withLock { state in
                    state.accepted.append(connection)
                    if !state.isOpen { state.pendingStart.append(connection) }
                    return state.isOpen
                }
                guard startNow else { return }
                server.receiveNext(on: connection)
                connection.start(queue: server.queue)
            }
            let resumed = OSAllocatedUnfairLock(initialState: false)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                server.listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready, .failed, .cancelled:
                        let alreadyResumed = resumed.withLock { (done: inout Bool) -> Bool in
                            let was = done
                            done = true
                            return was
                        }
                        if !alreadyResumed { continuation.resume() }
                    default:
                        break
                    }
                }
                server.listener.start(queue: server.queue)
            }
            return server
        }

        /// Releases a gated server: starts every held-back connection so
        /// their pending WS handshakes complete, and starts future ones
        /// immediately.
        func open() {
            let held = state.withLock { state in
                state.isOpen = true
                let pending = state.pendingStart
                state.pendingStart.removeAll()
                return pending
            }
            for connection in held {
                receiveNext(on: connection)
                connection.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
            state.withLock { state in
                for connection in state.accepted { connection.cancel() }
                state.accepted.removeAll()
                state.pendingStart.removeAll()
            }
        }

        private func receiveNext(on connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self, error == nil else { return }
                if let data,
                   let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let id = json["id"] {
                    let response: [String: Any] = [
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": [String: Any]()
                    ]
                    if let payload = try? JSONSerialization.data(withJSONObject: response) {
                        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
                        let context = NWConnection.ContentContext(
                            identifier: "response",
                            metadata: [metadata]
                        )
                        connection.send(
                            content: payload,
                            contentContext: context,
                            completion: .idempotent
                        )
                    }
                }
                receiveNext(on: connection)
            }
        }
    }

    /// A loopback port with nothing listening on it, so connections are
    /// refused fast and deterministically.
    private static func unusedLoopbackPort() async throws -> Int {
        let server = try await LoopbackWebSocketServer.start()
        let port = server.port
        server.stop()
        return port
    }

    /// Regression for monorepo#4185: a pairing attempt (QR / manual token /
    /// intent:// link all funnel into `connect()`) that fails while a live
    /// connection is active must NOT strand the app in `.connecting` on a
    /// dead socket — the existing connection keeps serving.
    @Test @MainActor func failedPairingOverLiveConnectionKeepsItServing() async throws {
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

    /// A tunnel dialer that reports a certificate mismatch only after a delay
    /// the race's loser cancellation cannot cut short, so a direct candidate
    /// wins first and the mismatch is reported by the background drain.
    nonisolated private struct SlowMismatchTunnelDialer: TunnelDialing {
        let fingerprint: String

        func open(tcAddress _: String, remotePort _: Int) async throws -> any TunnelSession {
            let mismatchDelayMilliseconds = 300
            _ = await Task.detached {
                try? await Task.sleep(for: .milliseconds(mismatchDelayMilliseconds))
            }.value
            throw WebSocketTransportError.certificateMismatch(
                host: ConnectionManager.tunnelCandidateLabel,
                fingerprint: fingerprint
            )
        }
    }

    /// A preserving connect() retires the old connection — advancing the
    /// connection generation — only AFTER its race is won. A slower losing
    /// candidate's certificate mismatch, reported by the background drain,
    /// must still reach `certMismatches`: the race was not superseded.
    @Test @MainActor func successfulPairingOverLiveConnectionKeepsLateLoserMismatch() async throws {
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

        manager.tunnelDialer = SlowMismatchTunnelDialer(fingerprint: "cc:dd")
        try await manager.connect(
            hosts: ["127.0.0.1"],
            port: serverB.port,
            token: "token-b",
            tcAddress: "tc-slow"
        )
        #expect(manager.connectionState == .connected)
        #expect(manager.port == serverB.port)
        #expect(manager.token == "token-b")

        let expected = [
            HostCertMismatch(
                host: ConnectionManager.tunnelCandidateLabel,
                fingerprint: "cc:dd"
            )
        ]
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline, manager.certMismatches != expected {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(manager.certMismatches == expected)
    }

    /// Two overlapping pairing attempts over a live connection: the OLDER
    /// attempt completing first must not install its target and supersede
    /// the newer one. Preserving connects don't tear down (and so don't
    /// advance the generation) up front, so ordering is carried by the
    /// connect-attempt counter: the older attempt is superseded, the newer
    /// one adopts its target.
    @Test @MainActor func olderOverlappingPairingAttemptDoesNotWin() async throws {
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

        // Both attempts hang in their WS handshake until their server opens.
        let older = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: olderTarget.port,
                token: "token-old"
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        let newer = Task {
            try await manager.connect(
                hosts: ["127.0.0.1"],
                port: newerTarget.port,
                token: "token-new"
            )
        }
        try await Task.sleep(for: .milliseconds(100))

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
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .reconnecting = manager.connectionState { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .reconnecting = manager.connectionState else {
            Issue.record("manager never entered .reconnecting after socket loss")
            return
        }

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
