import CryptoKit
import Foundation
import Network
import os

nonisolated enum WebSocketTransportError: LocalizedError, Sendable {
    case invalidURL(host: String)
    case timedOut(host: String)
    case failed(host: String, message: String)
    case disconnected(host: String, code: Int, reason: String)
    case certificateMismatch(host: String, fingerprint: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let host):
            "Invalid WebSocket URL for \(host)"
        case .timedOut(let host):
            "Connection to \(host) timed out"
        case .failed(let host, let message):
            "Connection to \(host) failed: \(message)"
        case .disconnected(let host, let code, let reason):
            "Disconnected from \(host) (\(code)): \(reason)"
        case .certificateMismatch(let host, let fingerprint):
            "Certificate fingerprint mismatch for \(host). Received: \(fingerprint)"
        }
    }

    var isCertificateMismatch: Bool {
        if case .certificateMismatch = self { return true }
        return false
    }
}

/// WebSocket transport built on Network.framework (NWConnection + NWProtocolWebSocket).
/// URLSession is deliberately not used: App Transport Security applies to URLSession
/// connections and blocks pinned self-signed wss connections to non-local hosts
/// (public IPs, Tailscale), while Network.framework leaves trust to the verify block
/// below — the SHA-256 certificate fingerprint is the sole trust decision.
actor WebSocketConnection {
    nonisolated let host: String

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let didOpen: OSAllocatedUnfairLock<Bool>

    /// Connect handshake deadline, matching the URLRequest.timeoutInterval the
    /// URLSession-based transport used.
    static let connectTimeout: Duration = .seconds(4)

    private init(
        host: String,
        connection: NWConnection,
        queue: DispatchQueue,
        didOpen: OSAllocatedUnfairLock<Bool>
    ) {
        self.host = host
        self.connection = connection
        self.queue = queue
        self.didOpen = didOpen
    }

    deinit {
        Self.close(connection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
    }

    // MARK: - URL / header / pinning helpers (pure, unit-testable)

    nonisolated static func makeURL(
        host: String,
        port: Int,
        certFingerprint: String?
    ) throws -> URL {
        let scheme = certFingerprint == nil ? "ws" : "wss"
        guard let url = URL(string: "\(scheme)://\(host):\(port)/ws") else {
            throw WebSocketTransportError.invalidURL(host: host)
        }
        return url
    }

    nonisolated static func additionalHeaders(token: String) -> [(name: String, value: String)] {
        [(name: "Authorization", value: "Bearer \(token)")]
    }

    /// SHA-256 fingerprint of a DER-encoded certificate, formatted as
    /// lowercase colon-separated hex — the normalization the pairing flow uses.
    nonisolated static func fingerprint(ofCertificate der: Data) -> String {
        SHA256.hash(data: der)
            .map { String(format: "%02x", $0) }
            .joined(separator: ":")
    }

    /// Case-insensitive fingerprint comparison — the sole trust decision for
    /// pinned connections.
    nonisolated static func fingerprintMatches(_ received: String, pinned: String) -> Bool {
        received.lowercased() == pinned.lowercased()
    }

    // MARK: - Connection setup

    private nonisolated static func makeParameters(
        host: String,
        token: String,
        certFingerprint: String?,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>,
        verifyQueue: DispatchQueue
    ) -> NWParameters {
        let parameters: NWParameters
        if let pinned = certFingerprint {
            let tlsOptions = NWProtocolTLS.Options()
            // Fingerprint pinning is the sole trust decision: the verify block
            // replaces default chain evaluation entirely (the daemon's cert is
            // self-signed), so SecTrustEvaluate is deliberately not called.
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { _, trustRef, complete in
                    let serverTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                    guard SecTrustGetCertificateCount(serverTrust) > 0,
                          let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                          let serverCert = certChain.first else {
                        AppLog.connection.error("[CertPinning] \(host): no server certificate presented")
                        complete(false)
                        return
                    }
                    let certData = SecCertificateCopyData(serverCert) as Data
                    let received = fingerprint(ofCertificate: certData)
                    if fingerprintMatches(received, pinned: pinned) {
                        complete(true)
                    } else {
                        AppLog.connection.error("[CertPinning] Fingerprint mismatch!")
                        AppLog.connection.error("[CertPinning] Expected: \(pinned)")
                        AppLog.connection.error("[CertPinning] Got:      \(received)")
                        mismatchFingerprint.withLock { $0 = received }
                        complete(false)
                    }
                },
                verifyQueue)
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = NWParameters.tcp
        }
        let wsOptions = NWProtocolWebSocket.Options()
        // Reply to daemon pings automatically (URLSessionWebSocketTask did the
        // same); the app's own liveness pings stay explicit via sendPing().
        wsOptions.autoReplyPing = true
        // Match the daemon's 40 MiB outbound JSON-RPC cap (docs/protocol §1.3).
        wsOptions.maximumMessageSize = 40 * 1024 * 1024
        wsOptions.setAdditionalHeaders(additionalHeaders(token: token))
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return parameters
    }

    nonisolated static func connect(
        host: String,
        port: Int,
        token: String,
        certFingerprint: String?
    ) async throws -> WebSocketConnection {
        let url = try makeURL(host: host, port: port, certFingerprint: certFingerprint)
        let mismatchFingerprint = OSAllocatedUnfairLock<String?>(initialState: nil)
        let didOpen = OSAllocatedUnfairLock(initialState: false)
        let queue = DispatchQueue(label: "WebSocketConnection.\(host)")
        let (lifecycleEvents, lifecycleContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let parameters = makeParameters(
            host: host,
            token: token,
            certFingerprint: certFingerprint,
            mismatchFingerprint: mismatchFingerprint,
            verifyQueue: queue)
        let nwConnection = NWConnection(to: .url(url), using: parameters)
        nwConnection.stateUpdateHandler = { state in
            switch state {
            case .setup, .preparing:
                AppLog.connection.debug("[WebSocket] \(host): \(String(describing: state))")
            case .ready:
                AppLog.connection.debug("[WebSocket] \(host): ready")
                didOpen.withLock { $0 = true }
                lifecycleContinuation.yield()
                lifecycleContinuation.finish()
            case .waiting(let error):
                // URLSession failed fast on unreachable hosts; NWConnection
                // retries in .waiting instead — surface it as a failure so
                // host racing moves on (includes TLS rejections from the
                // verify block, mapped to certificateMismatch by connect).
                AppLog.connection.error("[WebSocket] \(host): waiting (\(String(describing: error)))")
                lifecycleContinuation.finish(throwing: WebSocketTransportError.failed(
                    host: host, message: String(describing: error)))
            case .failed(let error):
                AppLog.connection.error("[WebSocket] \(host): failed (\(String(describing: error)))")
                lifecycleContinuation.finish(throwing: WebSocketTransportError.failed(
                    host: host, message: String(describing: error)))
            case .cancelled:
                AppLog.connection.debug("[WebSocket] \(host): cancelled")
                lifecycleContinuation.finish(throwing: WebSocketTransportError.failed(
                    host: host, message: "Connection cancelled before opening"))
            @unknown default:
                break
            }
        }
        let connection = WebSocketConnection(
            host: host, connection: nwConnection, queue: queue, didOpen: didOpen)

        do {
            try await withTaskCancellationHandler {
                nwConnection.start(queue: queue)
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        for try await _ in lifecycleEvents { return }
                        throw WebSocketTransportError.failed(
                            host: host, message: "Handshake ended before the socket opened")
                    }
                    group.addTask {
                        try await Task.sleep(for: connectTimeout)
                        throw WebSocketTransportError.timedOut(host: host)
                    }
                    do {
                        guard let _ = try await group.next() else {
                            throw WebSocketTransportError.failed(
                                host: host, message: "Handshake produced no result")
                        }
                        group.cancelAll()
                    } catch {
                        group.cancelAll()
                        throw error
                    }
                }
            } onCancel: {
                Self.close(nwConnection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
            }
            try Task.checkCancellation()
            return connection
        } catch {
            Self.close(nwConnection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
            if let fingerprint = mismatchFingerprint.withLock({ $0 }) {
                throw WebSocketTransportError.certificateMismatch(
                    host: host, fingerprint: fingerprint)
            }
            if let transportError = error as? WebSocketTransportError {
                throw transportError
            }
            if error is CancellationError {
                throw error
            }
            throw WebSocketTransportError.failed(host: host, message: error.localizedDescription)
        }
    }

    // MARK: - Messaging

    /// A received websocket frame, classified off the NWConnection callback so
    /// only Sendable payloads cross back into the actor.
    private enum Frame: Sendable {
        case fragment(kind: FragmentKind, data: Data, isComplete: Bool)
        case closed(code: Int, reason: String)
        case control
        case ended
    }

    nonisolated enum FragmentKind: Sendable {
        case text
        case binary
        case continuation
    }

    /// Reassembles fragmented websocket messages: NWConnection.receiveMessage
    /// may deliver a message in chunks (isComplete false, then .cont frames),
    /// where URLSessionWebSocketTask.receive() always delivered whole messages.
    /// Pure and unit-testable; text is UTF-8-decoded only once the message is
    /// complete so multi-byte characters split across fragments stay intact.
    nonisolated struct MessageAssembler {
        private var pendingIsText: Bool?
        private var buffer = Data()

        mutating func consume(
            kind: FragmentKind,
            data: Data,
            isComplete: Bool
        ) -> URLSessionWebSocketTask.Message? {
            switch kind {
            case .text:
                pendingIsText = true
                buffer = data
            case .binary:
                pendingIsText = false
                buffer = data
            case .continuation:
                // A continuation with no message in progress is a protocol
                // violation; drop it rather than fabricate a message.
                guard pendingIsText != nil else { return nil }
                buffer.append(data)
            }
            guard isComplete, let isText = pendingIsText else { return nil }
            defer {
                pendingIsText = nil
                buffer = Data()
            }
            return isText ? .string(String(decoding: buffer, as: UTF8.self)) : .data(buffer)
        }
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let connection = connection
        let didOpen = didOpen
        let queue = queue
        let host = host
        var assembler = MessageAssembler()
        while true {
            let frame: Frame = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    connection.receiveMessage { content, context, isComplete, error in
                        if let error {
                            continuation.resume(throwing: WebSocketTransportError.failed(
                                host: host, message: String(describing: error)))
                            return
                        }
                        continuation.resume(returning: Self.classifyFrame(
                            content: content, context: context, isComplete: isComplete))
                    }
                }
            } onCancel: {
                Self.close(connection, didOpen: didOpen, code: .protocolCode(.normalClosure), queue: queue)
            }
            switch frame {
            case .fragment(let kind, let data, let isComplete):
                if let message = assembler.consume(kind: kind, data: data, isComplete: isComplete) {
                    return message
                }
            case .closed(let code, let reason):
                AppLog.connection.debug("[WebSocket] \(host): remote close code=\(code) reason=\(reason)")
                throw WebSocketTransportError.disconnected(host: host, code: code, reason: reason)
            case .ended:
                // No error and no websocket metadata: the connection ended
                // without a close frame (RFC 6455 abnormal closure).
                throw WebSocketTransportError.disconnected(
                    host: host, code: 1006, reason: "Connection closed")
            case .control:
                continue
            }
        }
    }

    private nonisolated static func classifyFrame(
        content: Data?,
        context: NWConnection.ContentContext?,
        isComplete: Bool
    ) -> Frame {
        guard let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
            as? NWProtocolWebSocket.Metadata else {
            return .ended
        }
        switch metadata.opcode {
        case .text:
            return .fragment(kind: .text, data: content ?? Data(), isComplete: isComplete)
        case .binary:
            return .fragment(kind: .binary, data: content ?? Data(), isComplete: isComplete)
        case .cont:
            return .fragment(kind: .continuation, data: content ?? Data(), isComplete: isComplete)
        case .close:
            let reason = content
                .flatMap { String(data: $0, encoding: .utf8) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "Connection closed"
            return .closed(code: closeCodeValue(metadata.closeCode), reason: reason)
        case .ping, .pong:
            return .control
        @unknown default:
            return .control
        }
    }

    private nonisolated static func closeCodeValue(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case .protocolCode(let definition):
            return Int(definition.rawValue)
        case .applicationCode(let value):
            return Int(value)
        case .privateCode(let value):
            return Int(value)
        @unknown default:
            return 1005  // no status received
        }
    }

    func send(_ text: String) async throws {
        let connection = connection
        let host = host
        let metadata = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "text", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: Data(text.utf8),
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: WebSocketTransportError.failed(
                            host: host, message: String(describing: error)))
                    } else {
                        continuation.resume(returning: ())
                    }
                })
        }
    }

    func sendPing() async throws {
        let pending = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>(initialState: nil)
        let timeoutTask = Task { [host] in
            do {
                try await Task.sleep(for: Constants.WebSocket.pingTimeout)
            } catch {
                return
            }
            let continuation = pending.withLock { state in
                defer { state = nil }
                return state
            }
            continuation?.resume(throwing: WebSocketTransportError.timedOut(host: host))
        }
        defer { timeoutTask.cancel() }

        let connection = connection
        let queue = queue
        let host = host
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let installed = pending.withLock { state in
                    guard !Task.isCancelled else { return false }
                    state = continuation
                    return true
                }
                guard installed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
                metadata.setPongHandler(queue) { error in
                    let continuation = pending.withLock { state in
                        defer { state = nil }
                        return state
                    }
                    if let error {
                        continuation?.resume(throwing: WebSocketTransportError.failed(
                            host: host, message: String(describing: error)))
                    } else {
                        continuation?.resume(returning: ())
                    }
                }
                let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
                connection.send(
                    content: nil,
                    contentContext: context,
                    isComplete: true,
                    completion: .contentProcessed { error in
                        // Success resolves via the pong handler above.
                        guard let error else { return }
                        let continuation = pending.withLock { state in
                            defer { state = nil }
                            return state
                        }
                        continuation?.resume(throwing: WebSocketTransportError.failed(
                            host: host, message: String(describing: error)))
                    })
            }
        } onCancel: {
            let continuation = pending.withLock { state in
                defer { state = nil }
                return state
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    func disconnect() {
        Self.close(connection, didOpen: didOpen, code: .protocolCode(.normalClosure), queue: queue)
    }

    /// Sends a websocket close frame (when the socket opened) and cancels the
    /// underlying connection. Safe to call repeatedly and from any context:
    /// once the connection is cancelled, further sends complete with an error
    /// and cancel() is idempotent.
    private nonisolated static func close(
        _ connection: NWConnection,
        didOpen: OSAllocatedUnfairLock<Bool>,
        code: NWProtocolWebSocket.CloseCode,
        queue: DispatchQueue
    ) {
        guard didOpen.withLock({ $0 }) else {
            connection.cancel()
            return
        }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .close)
        metadata.closeCode = code
        let context = NWConnection.ContentContext(identifier: "close", metadata: [metadata])
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { _ in connection.cancel() })
        // An unresponsive peer or dead path can leave the close-frame send
        // pending forever; guarantee teardown with a fallback cancel after a
        // grace period (cancel() is idempotent).
        queue.asyncAfter(
            deadline: .now() + Constants.WebSocket.closeCancellationGracePeriod
        ) { connection.cancel() }
    }
}

