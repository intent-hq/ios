import Foundation

#if canImport(TailcatKit)
import TailcatKit
#endif

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

/// Dialer for platforms without a TailcatKit build (visionOS has no xros
/// slice yet — see TailcatKit/build_xcframework.sh): every dial fails fast
/// with a clear error, so a tunnel candidate degrades gracefully instead of
/// crashing. Compiled on every platform for test visibility.
nonisolated struct UnavailableTunnelDialer: TunnelDialing {
    static let unavailableMessage = "Tailcat tunnels are not supported on this platform"

    func open(tcAddress _: String, remotePort _: Int) async throws -> any TunnelSession {
        throw WebSocketTransportError.failed(
            host: ConnectionManager.tunnelCandidateLabel,
            message: Self.unavailableMessage
        )
    }
}

#if canImport(TailcatKit)

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
    private static let millisecondsPerSecond: CFTimeInterval = 1000

    /// Bridges task cancellation to the blocking gomobile dial: `cancel()`
    /// records the cancellation and closes the in-flight client so a blocked
    /// `ping` is torn down rather than left running unowned. The close runs
    /// OFF the cancelling thread: gomobile `close()` takes the same Go mutex
    /// that first-use startup (DERP map fetch, engine start) holds for its
    /// whole duration, so a synchronous close inside a cancellation handler
    /// would block whoever called `Task.cancel()` — possibly the main actor —
    /// until startup finished. `@unchecked Sendable`: state is lock-guarded.
    /// Internal for test visibility.
    ///
    /// What the gomobile close can and cannot interrupt (tailcat `Client`):
    /// - Before first use, `Close()` is a no-op (nothing is started yet), so
    ///   a cancel landing between `register` and the ping's startup closes
    ///   nothing and the stack still starts afterwards. The dial thread
    ///   re-checks `isCancelled` once `ping` returns and tears down itself.
    /// - During startup, `Close()` blocks on the startup mutex and only closes
    ///   once startup finished; it cannot abort a DERP map fetch in flight.
    /// - During the meow wait, `Close()` closes the engine but does not wake
    ///   the wait, which runs to its own internal 10 s cap.
    /// Cancellation therefore never shortens `ping`; it only guarantees
    /// teardown. `raceCandidates` no longer waits on losers, so this cost is
    /// off the connect critical path; the log lines below measure it.
    nonisolated final class DialHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var client: TailcatkitClient?
        private var cancelledAtLocked: CFAbsoluteTime?

        /// Registers the dialing client; returns false when the dial was
        /// already cancelled (the caller must close it and bail).
        func register(_ client: TailcatkitClient) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelledAtLocked != nil { return false }
            self.client = client
            return true
        }

        var isCancelled: Bool { cancelledAt != nil }

        /// When `cancel()` first ran, or nil while the dial is still wanted.
        var cancelledAt: CFAbsoluteTime? {
            lock.lock()
            defer { lock.unlock() }
            return cancelledAtLocked
        }

        /// Idempotent: only the first call records the time and closes.
        func cancel() {
            lock.lock()
            guard cancelledAtLocked == nil else {
                lock.unlock()
                return
            }
            let cancelTime = CFAbsoluteTimeGetCurrent()
            cancelledAtLocked = cancelTime
            let registered = client != nil
            lock.unlock()
            // Pre-registration: the dial thread closes the client itself
            // when `register` fails.
            guard registered else { return }
            // Captures self (lock-guarded) rather than the non-Sendable
            // gomobile client; `client` is never unset once registered.
            DispatchQueue.global(qos: .utility).async { [self] in
                lock.lock()
                let inFlight = client
                lock.unlock()
                try? inFlight?.close()
                let closeMs = Int(
                    (CFAbsoluteTimeGetCurrent() - cancelTime) * TailcatTunnelDialer.millisecondsPerSecond
                )
                AppLog.connection.debug("[TailcatTunnel] Dial cancelled: client.close() returned \(closeMs)ms after cancel")
            }
        }
    }

    private static func logFinished(
        _ outcome: String,
        dialStart: CFAbsoluteTime,
        handle: DialHandle
    ) {
        let now = CFAbsoluteTimeGetCurrent()
        var detail = "\(outcome) in \(Int((now - dialStart) * millisecondsPerSecond))ms"
        if let cancelledAt = handle.cancelledAt {
            detail += " (cancelled at +\(Int((cancelledAt - dialStart) * millisecondsPerSecond))ms, cancel→teardown \(Int((now - cancelledAt) * millisecondsPerSecond))ms)"
        }
        AppLog.connection.debug("[TailcatTunnel] Dial \(detail)")
    }

    private static func completeOpen(
        tcAddress: String,
        remotePort: Int,
        handle: DialHandle,
        dialStart: CFAbsoluteTime,
        continuation: CheckedContinuation<any TunnelSession, Error>
    ) {
        guard let client = TailcatkitNewClient(tcAddress) else {
            logFinished("failed: client init", dialStart: dialStart, handle: handle)
            continuation.resume(throwing: WebSocketTransportError.failed(
                host: ConnectionManager.tunnelCandidateLabel,
                message: "TailcatKit client init failed"
            ))
            return
        }
        guard handle.register(client) else {
            try? client.close()
            logFinished("cancelled before start", dialStart: dialStart, handle: handle)
            continuation.resume(throwing: CancellationError())
            return
        }
        do {
            let pingStart = CFAbsoluteTimeGetCurrent()
            let pingResult = Result { try client.ping(establishTimeoutMs) }
            let pingMs = Int((CFAbsoluteTimeGetCurrent() - pingStart) * millisecondsPerSecond)
            if let cancelledAt = handle.cancelledAt {
                let latencyMs = Int((CFAbsoluteTimeGetCurrent() - cancelledAt) * millisecondsPerSecond)
                AppLog.connection.debug("[TailcatTunnel] Dial cancelled before ping returned: ping returned \(latencyMs)ms after cancel (ping took \(pingMs)ms)")
                try? client.close()
                logFinished("cancelled before ping returned", dialStart: dialStart, handle: handle)
                continuation.resume(throwing: CancellationError())
                return
            }
            try pingResult.get()
            let forwarder = try client.forward(remotePort)
            logFinished("established (ping \(pingMs)ms)", dialStart: dialStart, handle: handle)
            continuation.resume(returning: TailcatTunnelSession(client: client, forwarder: forwarder))
        } catch {
            try? client.close()
            logFinished("failed: \(error.localizedDescription)", dialStart: dialStart, handle: handle)
            continuation.resume(throwing: error)
        }
    }

    func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession {
        let handle = DialHandle()
        let dialStart = CFAbsoluteTimeGetCurrent()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    Self.completeOpen(
                        tcAddress: tcAddress,
                        remotePort: remotePort,
                        handle: handle,
                        dialStart: dialStart,
                        continuation: continuation
                    )
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }
}

#endif
