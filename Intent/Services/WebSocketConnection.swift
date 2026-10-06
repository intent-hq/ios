import Foundation
import Network
import os

/// WebSocket transport built on Network.framework (NWConnection + NWProtocolWebSocket).
/// URLSession is deliberately not used: App Transport Security applies to URLSession
/// connections and blocks pinned self-signed wss connections to non-local hosts
/// (public IPs, Tailscale), while Network.framework leaves trust to the verify block
/// below — the SHA-256 certificate fingerprint is the sole trust decision.
actor WebSocketConnection {
    nonisolated let host: String
    nonisolated let pathObservation: SocketPathObservation
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let didOpen: OSAllocatedUnfairLock<Bool>

    /// Connect handshake deadline, matching the URLRequest.timeoutInterval the
    /// URLSession-based transport used.
    private static let connectTimeoutSeconds: Int = 4
    static let connectTimeout: Duration = .seconds(connectTimeoutSeconds)
    private static let maximumMessageSizeMebibytes: Int = 40
    private static let kibibytesPerMebibyte: Int = 1024
    private static let bytesPerKibibyte: Int = 1024
    static let maximumMessageSize =
        maximumMessageSizeMebibytes * kibibytesPerMebibyte * bytesPerKibibyte
    private static let abnormalClosureCode = 1006
    private static let invalidFramePayloadCode = 1007
    private static let missingCloseStatusCode = 1005

    private init(
        host: String,
        connection: NWConnection,
        queue: DispatchQueue,
        didOpen: OSAllocatedUnfairLock<Bool>,
        pathObservation: SocketPathObservation
    ) {
        self.host = host
        self.connection = connection
        self.queue = queue
        self.didOpen = didOpen
        self.pathObservation = pathObservation
    }

    deinit {
        pathObservation.stop()
        Self.close(connection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
    }

    // MARK: - Connection setup
    // swiftlint:disable:next function_parameter_count
    nonisolated private static func makeParameters(
        host: String,
        token: String,
        certFingerprint: String?,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>,
        missingCertificate: OSAllocatedUnfairLock<Bool>,
        verifyQueue: DispatchQueue,
        endpoint: Endpoint
    ) -> NWParameters {
        let parameters: NWParameters
        if let pinned = trustedPin(certFingerprint) {
            let tlsOptions = NWProtocolTLS.Options()
            // Fingerprint pinning is the sole trust decision: the verify block
            // replaces default chain evaluation entirely (the daemon's cert is
            // self-signed), so SecTrustEvaluate is deliberately not called.
            sec_protocol_options_set_verify_block(
                tlsOptions.securityProtocolOptions,
                { @Sendable _, trustRef, complete in
                    let serverTrust = sec_trust_copy_ref(trustRef).takeRetainedValue()
                    guard SecTrustGetCertificateCount(serverTrust) > 0,
                          let certChain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
                          let serverCert = certChain.first else {
                        AppLog.connection.error("[CertPinning] \(host): no server certificate presented")
                        missingCertificate.withLock { $0 = true }
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
                verifyQueue
            )
            parameters = NWParameters(tls: tlsOptions)
        } else {
            parameters = NWParameters.tcp
        }
        let wsOptions = NWProtocolWebSocket.Options()
        // Reply to daemon pings automatically (URLSessionWebSocketTask did the
        // same); the app's own liveness pings stay explicit via sendPing().
        wsOptions.autoReplyPing = true
        // The binary tunnel has its own smaller message cap (docs/protocol §1.4).
        wsOptions.maximumMessageSize = endpoint.maximumMessageSize
        wsOptions.setAdditionalHeaders(additionalHeaders(token: token))
        parameters.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        return parameters
    }

    nonisolated private static func configureStateHandler(
        _ connection: NWConnection,
        host: String,
        didOpen: OSAllocatedUnfairLock<Bool>,
        pathObservation: SocketPathObservation,
        continuation: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        connection.pathUpdateHandler = { @Sendable path in
            pathObservation.pathChanged(NetworkPathSnapshot(path))
        }
        connection.viabilityUpdateHandler = { @Sendable isViable in
            pathObservation.viabilityChanged(isViable)
        }
        // Preserve lifecycle ordering while retaining typed failure provenance.
        // swiftlint:disable:next closure_body_length
        connection.stateUpdateHandler = { @Sendable [weak connection] state in
            switch state {
            case .setup, .preparing:
                AppLog.connection.debug("[WebSocket] \(host): \(String(describing: state))")
            case .ready:
                AppLog.connection.debug("[WebSocket] \(host): ready")
                pathObservation.ready(path: connection?.currentPath.map { NetworkPathSnapshot($0) })
                didOpen.withLock { $0 = true }
                continuation.yield()
                continuation.finish()
            case .waiting(let error):
                pathObservation.viabilityChanged(false)
                AppLog.connection.error("[WebSocket] \(host): waiting (\(String(describing: error)))")
                continuation.finish(throwing: WebSocketTransportError.failed(
                    host: host,
                    message: String(describing: error),
                    diagnosticFailure: TransportDiagnosticFailure.classify(error)
                ))
            case .failed(let error):
                pathObservation.viabilityChanged(false)
                AppLog.connection.error("[WebSocket] \(host): failed (\(String(describing: error)))")
                continuation.finish(throwing: WebSocketTransportError.failed(
                    host: host,
                    message: String(describing: error),
                    diagnosticFailure: TransportDiagnosticFailure.classify(error)
                ))
            case .cancelled:
                pathObservation.stop()
                AppLog.connection.debug("[WebSocket] \(host): cancelled")
                continuation.finish(throwing: WebSocketTransportError.failed(
                    host: host, message: "Connection cancelled before opening"
                ))
            @unknown default:
                break
            }
        }
    }

    nonisolated private static func awaitOpening(
        _ connection: NWConnection,
        didOpen: OSAllocatedUnfairLock<Bool>,
        queue: DispatchQueue,
        lifecycleEvents: AsyncThrowingStream<Void, Error>,
        host: String
    ) async throws {
        try await withTaskCancellationHandler {
            connection.start(queue: queue)
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    for try await _ in lifecycleEvents { return }
                    throw WebSocketTransportError.failed(
                        host: host,
                        message: "Handshake ended before the socket opened"
                    )
                }
                group.addTask {
                    try await Task.sleep(for: connectTimeout)
                    throw WebSocketTransportError.timedOut(host: host)
                }
                do {
                    guard try await group.next() != nil else {
                        throw WebSocketTransportError.failed(
                            host: host,
                            message: "Handshake produced no result"
                        )
                    }
                    group.cancelAll()
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            close(connection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
        }
    }

    // Keep trust classification next to the existing handshake cleanup.
    // swiftlint:disable:next function_body_length
    nonisolated static func connect(
        host: String,
        port: Int,
        token: String,
        certFingerprint: String?,
        endpoint: Endpoint = .rpc
    ) async throws -> WebSocketConnection {
        let url = try makeURL(host: host, port: port, certFingerprint: certFingerprint, endpoint: endpoint)
        let mismatchFingerprint = OSAllocatedUnfairLock<String?>(initialState: nil)
        let missingCertificate = OSAllocatedUnfairLock(initialState: false)
        let didOpen = OSAllocatedUnfairLock(initialState: false)
        let pathObservation = SocketPathObservation()
        let queue = DispatchQueue(label: "WebSocketConnection.\(host)")
        let (lifecycleEvents, lifecycleContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let parameters = makeParameters(
            host: host,
            token: token,
            certFingerprint: certFingerprint,
            mismatchFingerprint: mismatchFingerprint,
            missingCertificate: missingCertificate,
            verifyQueue: queue,
            endpoint: endpoint
        )
        let nwConnection = NWConnection(to: .url(url), using: parameters)
        configureStateHandler(
            nwConnection,
            host: host,
            didOpen: didOpen,
            pathObservation: pathObservation,
            continuation: lifecycleContinuation
        )
        do {
            try await awaitOpening(
                nwConnection,
                didOpen: didOpen,
                queue: queue,
                lifecycleEvents: lifecycleEvents,
                host: host
            )
            try Task.checkCancellation()
            return WebSocketConnection(
                host: host,
                connection: nwConnection,
                queue: queue,
                didOpen: didOpen,
                pathObservation: pathObservation
            )
        } catch {
            pathObservation.stop()
            Self.close(nwConnection, didOpen: didOpen, code: .protocolCode(.goingAway), queue: queue)
            if !Task.isCancelled, missingCertificate.withLock({ $0 }),
               case let .failed(host, message, _) = error as? WebSocketTransportError {
                throw WebSocketTransportError.failed(
                    host: host,
                    message: message,
                    diagnosticFailure: DiagnosticFailure(origin: .transport, classification: .noCertificate)
                )
            }
            throw WebSocketPingSupport.mappedConnectionError(
                error,
                mismatchFingerprint: mismatchFingerprint,
                host: host
            )
        }
    }
}

extension WebSocketConnection {
    // MARK: - Messaging

    /// A received websocket frame, classified off the NWConnection callback so
    /// only Sendable payloads cross back into the actor.
    private enum Frame: Sendable {
        case fragment(kind: FragmentKind, data: Data, isComplete: Bool)
        case closed(code: Int, reason: String)
        case control
        case ended
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
                                host: host,
                                message: String(describing: error),
                                diagnosticFailure: TransportDiagnosticFailure.classify(error)
                            ))
                            return
                        }
                        continuation.resume(returning: Self.classifyFrame(
                            content: content,
                            context: context,
                            isComplete: isComplete
                        ))
                    }
                }
            } onCancel: {
                Self.close(connection, didOpen: didOpen, code: .protocolCode(.normalClosure), queue: queue)
            }
            switch frame {
            case let .fragment(kind, data, isComplete):
                if let message = try assembledMessage(
                    kind: kind,
                    data: data,
                    isComplete: isComplete,
                    assembler: &assembler
                ) {
                    return message
                }
            case let .closed(code, reason):
                AppLog.connection.debug("[WebSocket] \(host): remote close code=\(code) reason=\(reason)")
                throw WebSocketTransportError.disconnected(host: host, code: code, reason: reason)
            case .ended:
                // No error and no websocket metadata: the connection ended
                // without a close frame (RFC 6455 abnormal closure).
                throw WebSocketTransportError.disconnected(
                    host: host,
                    code: Self.abnormalClosureCode,
                    reason: "Connection closed"
                )
            case .control:
                continue
            }
        }
    }

    private func assembledMessage(
        kind: FragmentKind,
        data: Data,
        isComplete: Bool,
        assembler: inout MessageAssembler
    ) throws -> URLSessionWebSocketTask.Message? {
        do {
            return try assembler.consume(kind: kind, data: data, isComplete: isComplete)
        } catch MessageAssemblyError.invalidTextEncoding {
            Self.close(
                connection,
                didOpen: didOpen,
                code: .protocolCode(.invalidFramePayloadData),
                queue: queue
            )
            throw WebSocketTransportError.disconnected(
                host: host,
                code: Self.invalidFramePayloadCode,
                reason: "Invalid UTF-8 text payload"
            )
        }
    }

    nonisolated private static func classifyFrame(
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

    nonisolated private static func closeCodeValue(_ code: NWProtocolWebSocket.CloseCode) -> Int {
        switch code {
        case .protocolCode(let definition):
            return Int(definition.rawValue)
        case .applicationCode(let value):
            return Int(value)
        case .privateCode(let value):
            return Int(value)
        @unknown default:
            return missingCloseStatusCode
        }
    }

    func send(_ text: String) async throws {
        try await sendPayload(Data(text.utf8), opcode: .text)
    }

    func send(_ data: Data) async throws {
        try await sendPayload(data, opcode: .binary)
    }

    private func sendPayload(_ data: Data, opcode: NWProtocolWebSocket.Opcode) async throws {
        let connection = connection
        let host = host
        let metadata = NWProtocolWebSocket.Metadata(opcode: opcode)
        let context = NWConnection.ContentContext(identifier: "message", metadata: [metadata])
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                contentContext: context,
                isComplete: true,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: WebSocketTransportError.failed(
                            host: host,
                            message: String(describing: error),
                            diagnosticFailure: TransportDiagnosticFailure.classify(error)
                        ))
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            )
        }
    }

    func sendPing() async throws {
        let pending = WebSocketPingSupport.PendingPing(initialState: nil)
        let timeoutTask = Task { [host] in
            do {
                try await Task.sleep(for: Constants.WebSocket.pingTimeout)
            } catch {
                return
            }
            WebSocketPingSupport.takePending(pending)?.resume(
                throwing: WebSocketTransportError.timedOut(host: host)
            )
        }
        defer { timeoutTask.cancel() }

        let connection = connection
        let queue = queue
        let host = host
        try await withTaskCancellationHandler {
            try await WebSocketPingSupport.performPing(
                connection: connection,
                pending: pending,
                queue: queue,
                host: host
            )
        } onCancel: {
            WebSocketPingSupport.takePending(pending)?.resume(throwing: CancellationError())
        }
    }

    func disconnect() {
        pathObservation.stop()
        Self.close(connection, didOpen: didOpen, code: .protocolCode(.normalClosure), queue: queue)
    }

    /// Sends a websocket close frame (when the socket opened) and cancels the
    /// underlying connection. Safe to call repeatedly and from any context:
    /// once the connection is cancelled, further sends complete with an error
    /// and cancel() is idempotent.
    nonisolated private static func close(
        _ connection: NWConnection,
        didOpen: OSAllocatedUnfairLock<Bool>,
        code: NWProtocolWebSocket.CloseCode,
        queue: DispatchQueue
    ) {
        connection.pathUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
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
            completion: .contentProcessed { _ in connection.cancel() }
        )
        // An unresponsive peer or dead path can leave the close-frame send
        // pending forever; guarantee teardown with a fallback cancel after a
        // grace period (cancel() is idempotent).
        queue.asyncAfter(
            deadline: .now() + Constants.WebSocket.closeCancellationGracePeriod
        ) { connection.cancel() }
    }
}
