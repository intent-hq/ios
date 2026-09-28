import Foundation
import Network

/// Explicitly binds IPv4 loopback, never an unspecified/all-interface address.
@MainActor
final class BrowserTunnelListener {
    private static let readyTimeoutSeconds = 5
    static let readyTimeout: Duration = .seconds(readyTimeoutSeconds)
    static let loopbackHost: NWEndpoint.Host = "127.0.0.1"

    private let listener: NWListener
    private let queue = DispatchQueue(label: "BrowserTunnel.listener")
    private var waiters: [CheckedContinuation<UInt16, Error>] = []
    private var timeout: Task<Void, Never>?
    private(set) var localPort: UInt16?
    private var started = false
    private var stopped = false
    var onAccept: (@MainActor (NWConnection) -> Void)?
    var onFailure: (@MainActor () -> Void)?

    static func parameters() -> NWParameters {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: loopbackHost, port: .any)
        return parameters
    }

    init() throws {
        listener = try NWListener(using: Self.parameters())
    }

    isolated deinit {
        listener.cancel()
        timeout?.cancel()
        for waiter in waiters { waiter.resume(throwing: BrowserTunnelError.closed) }
    }

    func ready() async throws -> UInt16 {
        try Task.checkCancellation()
        if let localPort { return localPort }
        guard !stopped else { throw BrowserTunnelError.closed }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(continuation)
                if !started { start() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    private func start() {
        started = true
        listener.newConnectionHandler = { @Sendable [weak self] connection in
            Task { @MainActor in
                guard let self, !self.stopped, let onAccept = self.onAccept else {
                    connection.cancel()
                    return
                }
                onAccept(connection)
            }
        }
        listener.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in self?.stateChanged(state) }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: Self.readyTimeout) } catch { return }
            self?.cancel(error: BrowserTunnelError.timedOut)
        }
        listener.start(queue: queue)
    }

    private func stateChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener.port?.rawValue else {
                cancel(error: BrowserTunnelError.unavailable)
                return
            }
            localPort = port
            timeout?.cancel()
            timeout = nil
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume(returning: port) }
        case .failed(let error):
            cancel(error: error)
        case .cancelled:
            cancel()
        default:
            break
        }
    }

    func cancel(error: any Error = BrowserTunnelError.closed) {
        guard !stopped else { return }
        stopped = true
        listener.newConnectionHandler = nil
        listener.stateUpdateHandler = nil
        listener.cancel()
        timeout?.cancel()
        timeout = nil
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: error) }
        onFailure?()
        onAccept = nil
        onFailure = nil
    }
}

/// Network callbacks remain off MainActor and transfer only Sendable values.
nonisolated enum BrowserTunnelTCP {
    static let readSize = 16_384

    static func read(_ connection: NWConnection) async throws -> (Data, Bool) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                connection.receive(minimumIncompleteLength: 1, maximumLength: readSize) { @Sendable data, _, ended, error in
                    if let error { continuation.resume(throwing: error) } else {
                        continuation.resume(returning: (data ?? Data(), ended))
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    static func write(_ data: Data?, to connection: NWConnection, eof: Bool = false) async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.send(
                    content: data,
                    contentContext: eof ? .finalMessage : .defaultMessage,
                    isComplete: true,
                    completion: .contentProcessed { @Sendable error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                )
            }
        } onCancel: {
            connection.cancel()
        }
    }
}
