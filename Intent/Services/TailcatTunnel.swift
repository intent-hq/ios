import Foundation

#if canImport(TailcatKit)
import TailcatKit
#endif

nonisolated protocol TunnelSession: Sendable {
    var localPort: Int { get }

    func close() async
}

nonisolated protocol TunnelDialing: Sendable {
    func open(tcAddress: String, remotePort: Int) async throws -> any TunnelSession
}

nonisolated struct UnavailableTunnelDialer: TunnelDialing {
    static let unavailableMessage = "Tailcat tunnels are not supported on this platform"

    func open(tcAddress _: String, remotePort _: Int) throws -> any TunnelSession {
        throw WebSocketTransportError.failed(
            host: ConnectionManager.tunnelCandidateLabel,
            message: Self.unavailableMessage
        )
    }
}

#if canImport(TailcatKit)

nonisolated protocol TunnelClientHandle {
    func close() throws
}

nonisolated protocol TunnelForwarderHandle {
    func port() -> Int
    func close() throws
}

nonisolated extension TailcatkitClient: TunnelClientHandle {}
nonisolated extension TailcatkitForwarder: TunnelForwarderHandle {}

nonisolated final class TailcatTunnelSession: TunnelSession, @unchecked Sendable {
    let localPort: Int
    private let client: any TunnelClientHandle
    private let forwarder: (any TunnelForwarderHandle)?
    private let lock = NSLock()
    private var closed = false

    init(client: any TunnelClientHandle, forwarder: (any TunnelForwarderHandle)?) {
        self.client = client
        self.forwarder = forwarder
        self.localPort = forwarder?.port() ?? 0
    }

    func close() async {
        guard markClosed() else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                try? forwarder?.close()
                try? client.close()
                continuation.resume()
            }
        }
    }

    private func markClosed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if closed { return false }
        closed = true
        return true
    }
}

nonisolated struct TailcatTunnelDialer: TunnelDialing {
    static let establishTimeoutMs = 20_000
    private static let millisecondsPerSecond: CFTimeInterval = 1000

    nonisolated final class DialHandle: @unchecked Sendable {
        private let lock = NSLock()
        private var client: (any TunnelClientHandle)?
        private var cancelledAtLocked: CFAbsoluteTime?

        func register(_ client: any TunnelClientHandle) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelledAtLocked != nil { return false }
            self.client = client
            return true
        }

        var isCancelled: Bool { cancelledAt != nil }

        var cancelledAt: CFAbsoluteTime? {
            lock.lock()
            defer { lock.unlock() }
            return cancelledAtLocked
        }

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
            guard registered else { return }
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
