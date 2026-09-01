import Foundation
import TailcatKit

/// A live tailcat tunnel session: a loopback forwarder piping
/// 127.0.0.1:`localPort` to the daemon's WSS port over the tunnel.
nonisolated protocol TunnelSession: Sendable {
    var localPort: Int { get }
    func close() async
}

/// Dials tailcat tunnels. Abstracted so the ConnectionManager race can be
/// tested with a faked framework.
nonisolated protocol TunnelDialing: Sendable {
    /// Establishes the tunnel to `tcAddress` and starts a loopback forwarder
    /// piping to `remotePort` on the daemon.
    func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession
}

/// TailcatKit-backed session: owns the gomobile client and its loopback
/// forwarder. `@unchecked Sendable`: the gomobile projections are thread-safe
/// handles to Go objects.
nonisolated final class TailcatTunnelSession: TunnelSession, @unchecked Sendable {
    let localPort: Int
    private let client: TailcatkitClient
    private let forwarder: TailcatkitForwarder

    init(client: TailcatkitClient, forwarder: TailcatkitForwarder) {
        self.client = client
        self.forwarder = forwarder
        self.localPort = forwarder.port()
    }

    func close() async {
        try? forwarder.close()
        try? client.close()
    }
}

/// Real dialer over the vendored TailcatKit.xcframework.
nonisolated struct TailcatTunnelDialer: TunnelDialing {
    /// Bound on tunnel establishment (the warm-up ping below), covering
    /// first-use DERP discovery + a relay round-trip. Deliberately much
    /// longer than `WebSocketConnection.connectTimeout`: the tunnel is the
    /// slow-path candidate and only needs to finish, not finish fast —
    /// reachable direct hosts win the race long before this.
    static let establishTimeoutMs = 20_000

    /// Bridges task cancellation to the blocking gomobile dial: `cancel()`
    /// closes the in-flight client so a blocked `ping` fails promptly instead
    /// of running out its full timeout. Without this, `raceCandidates` (which
    /// drains its whole group before returning) would stall the race on the
    /// tunnel candidate for up to `establishTimeoutMs` after a direct host
    /// already won. `@unchecked Sendable`: state is lock-guarded.
    private final class DialHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var client: TailcatkitClient?
        private var cancelled = false

        /// Registers the dialing client; returns false when the dial was
        /// already cancelled (the caller must close it and bail).
        func register(_ client: TailcatkitClient) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            self.client = client
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let inFlight = client
            lock.unlock()
            try? inFlight?.close()
        }
    }

    func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
        let handle = DialHandle()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // The gomobile calls block; keep them off the cooperative pool.
                DispatchQueue.global(qos: .userInitiated).async {
                    guard let client = TailcatkitNewClient(tcAddress) else {
                        continuation.resume(throwing: WebSocketTransportError.failed(
                            host: ConnectionManager.tunnelCandidateLabel,
                            message: "TailcatKit client init failed"))
                        return
                    }
                    guard handle.register(client) else {
                        try? client.close()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    do {
                        // Warm the tunnel with a relay round-trip BEFORE exposing
                        // the loopback forwarder: the local TCP connect succeeds
                        // instantly, so without this the WebSocket handshake
                        // deadline would tick against tunnel establishment.
                        try client.ping(Self.establishTimeoutMs)
                        let forwarder = try client.forward(remotePort)
                        continuation.resume(
                            returning: TailcatTunnelSession(client: client, forwarder: forwarder))
                    } catch {
                        try? client.close()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}
