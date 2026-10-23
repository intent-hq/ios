import Foundation
import Network
import os

/// WebSocket transport over a Network.framework TLS byte stream. The RFC 6455
/// handshake and framing, and RFC 7692 permessage-deflate, run in Swift
/// (`WebSocketHandshake`, `WebSocketFrameCodec`, `PerMessageDeflate`) because
/// `NWProtocolWebSocket` aborts any handshake in which the server accepts an
/// extension, so it cannot compress.
/// URLSession is deliberately not used: App Transport Security applies to URLSession
/// connections and blocks pinned self-signed wss connections to non-local hosts
/// (public IPs, Tailscale), while Network.framework leaves trust to the verify block
/// below — the SHA-256 certificate fingerprint is the sole trust decision.
actor WebSocketConnection {
    nonisolated let host: String
    nonisolated let pathObservation: SocketPathObservation
    /// The extension the server accepted, for logs and tests; nil when the
    /// connection is uncompressed.
    nonisolated let negotiatedDeflate: PerMessageDeflateParameters?
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let lifecycle: Lifecycle
    private let deflate: PerMessageDeflate?
    private var inbound: InboundStream
    private var pendingPings: [Data: WebSocketPingSupport.PendingPing] = [:]
    private var nextPingID: UInt64 = 0

    /// Offer permessage-deflate on every connection. Setting this to false
    /// restores a plain RFC 6455 connection (no extension header), the
    /// rollback path for compression.
    nonisolated static let offersPermessageDeflate = true

    /// Connect handshake deadline, matching the URLRequest.timeoutInterval the
    /// URLSession-based transport used. Covers TCP, TLS, and the HTTP upgrade.
    private static let connectTimeoutSeconds: Int = 4
    static let connectTimeout: Duration = .seconds(connectTimeoutSeconds)
    private static let maximumMessageSizeMebibytes: Int = 40
    private static let kibibytesPerMebibyte: Int = 1024
    private static let bytesPerKibibyte: Int = 1024
    static let maximumMessageSize =
        maximumMessageSizeMebibytes * kibibytesPerMebibyte * bytesPerKibibyte
    static let readChunkSize = 65_536

    /// Socket lifecycle shared with nonisolated teardown paths: a close frame
    /// is sent only once, and only after the upgrade completed.
    nonisolated enum SocketState: Sendable {
        case connecting
        case open
        case closing
    }

    typealias Lifecycle = OSAllocatedUnfairLock<SocketState>

    private init(
        host: String,
        connection: NWConnection,
        queue: DispatchQueue,
        lifecycle: Lifecycle,
        pathObservation: SocketPathObservation,
        endpoint: Endpoint,
        upgrade: Upgrade
    ) throws {
        self.host = host
        self.connection = connection
        self.queue = queue
        self.lifecycle = lifecycle
        self.pathObservation = pathObservation
        negotiatedDeflate = upgrade.deflate
        let deflate = try upgrade.deflate.map { try PerMessageDeflate(parameters: $0) }
        self.deflate = deflate
        inbound = InboundStream(maximumMessageSize: endpoint.maximumMessageSize, deflate: deflate)
        inbound.append(upgrade.leftover)
    }

    deinit {
        pathObservation.stop()
        Self.close(connection, lifecycle: lifecycle, code: WebSocketCloseCode.goingAway, queue: queue)
    }

    // MARK: - Connection setup
    // TLS verification needs the endpoint, credentials, result locks, and callback queue independently.
    nonisolated private static func makeParameters(
        host: String,
        certFingerprint: String?,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>,
        missingCertificate: OSAllocatedUnfairLock<Bool>,
        verifyQueue: DispatchQueue
    ) -> NWParameters {
        guard let pinned = trustedPin(certFingerprint) else { return NWParameters.tcp }
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
        return NWParameters(tls: tlsOptions)
    }

    nonisolated private static func configureStateHandler(
        _ connection: NWConnection,
        host: String,
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
        connection.stateUpdateHandler = { @Sendable [weak connection] state in
            switch state {
            case .setup, .preparing:
                AppLog.connection.debug("[WebSocket] \(host): \(String(describing: state))")
            case .ready:
                AppLog.connection.debug("[WebSocket] \(host): transport ready")
                pathObservation.ready(path: connection?.currentPath.map { NetworkPathSnapshot($0) })
                continuation.yield()
                continuation.finish()
            case .waiting, .failed:
                finishWithFailure(state, host: host, pathObservation: pathObservation, continuation: continuation)
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

    nonisolated private static func finishWithFailure(
        _ state: NWConnection.State,
        host: String,
        pathObservation: SocketPathObservation,
        continuation: AsyncThrowingStream<Void, Error>.Continuation
    ) {
        let error: NWError
        switch state {
        case .waiting(let failure):
            error = failure
            pathObservation.viabilityChanged(false)
            AppLog.connection.error("[WebSocket] \(host): waiting (\(String(describing: error)))")
        case .failed(let failure):
            error = failure
            pathObservation.viabilityChanged(false)
            AppLog.connection.error("[WebSocket] \(host): failed (\(String(describing: error)))")
        default:
            return
        }
        continuation.finish(throwing: WebSocketTransportError.failed(
            host: host, message: String(describing: error), diagnosticFailure: TransportDiagnosticFailure.classify(error)
        ))
    }

    // Starts the connection and, once TCP/TLS is ready, runs `upgrade`, all
    // within `connectTimeout`. Teardown on cancellation needs the connection,
    // lifecycle, and queue independently.
    // swiftlint:disable:next function_parameter_count
    nonisolated private static func awaitOpening(
        _ connection: NWConnection,
        lifecycle: Lifecycle,
        queue: DispatchQueue,
        lifecycleEvents: AsyncThrowingStream<Void, Error>,
        host: String,
        upgrade: @escaping @Sendable () async throws -> Upgrade
    ) async throws -> Upgrade {
        try await withTaskCancellationHandler {
            connection.start(queue: queue)
            return try await withThrowingTaskGroup(of: Upgrade.self) { group in
                group.addTask {
                    for try await _ in lifecycleEvents { return try await upgrade() }
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
                    guard let result = try await group.next() else {
                        throw WebSocketTransportError.failed(
                            host: host,
                            message: "Handshake produced no result"
                        )
                    }
                    group.cancelAll()
                    return result
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } onCancel: {
            close(connection, lifecycle: lifecycle, code: WebSocketCloseCode.goingAway, queue: queue)
        }
    }

    // The public entry point keeps its long-standing parameter list; the
    // compression flag defaults to the kill switch.
    // swiftlint:disable:next function_body_length
    nonisolated static func connect(
        host: String,
        port: Int,
        token: String,
        certFingerprint: String?,
        endpoint: Endpoint = .rpc,
        offersCompression: Bool = offersPermessageDeflate
    ) async throws -> WebSocketConnection {
        let url = try makeURL(host: host, port: port, certFingerprint: certFingerprint, endpoint: endpoint)
        let mismatchFingerprint = OSAllocatedUnfairLock<String?>(initialState: nil)
        let missingCertificate = OSAllocatedUnfairLock(initialState: false)
        let lifecycle = Lifecycle(initialState: .connecting)
        let pathObservation = SocketPathObservation()
        let queue = DispatchQueue(label: "WebSocketConnection.\(host)")
        let (lifecycleEvents, lifecycleContinuation) = AsyncThrowingStream<Void, Error>.makeStream()
        let parameters = makeParameters(
            host: host,
            certFingerprint: certFingerprint,
            mismatchFingerprint: mismatchFingerprint,
            missingCertificate: missingCertificate,
            verifyQueue: queue
        )
        let nwConnection = NWConnection(to: .url(url), using: parameters)
        configureStateHandler(
            nwConnection,
            host: host,
            pathObservation: pathObservation,
            continuation: lifecycleContinuation
        )
        do {
            let upgrade = try await awaitOpening(
                nwConnection,
                lifecycle: lifecycle,
                queue: queue,
                lifecycleEvents: lifecycleEvents,
                host: host
            ) {
                try await performUpgrade(nwConnection, url: url, token: token, offersCompression: offersCompression, host: host)
            }
            try Task.checkCancellation()
            let socket = try WebSocketConnection(
                host: host,
                connection: nwConnection,
                queue: queue,
                lifecycle: lifecycle,
                pathObservation: pathObservation,
                endpoint: endpoint,
                upgrade: upgrade
            )
            lifecycle.withLock { $0 = .open }
            AppLog.connection.debug(
                "[WebSocket] \(host): open (\(upgrade.deflate == nil ? "uncompressed" : "permessage-deflate"))"
            )
            return socket
        } catch {
            pathObservation.stop()
            Self.close(nwConnection, lifecycle: lifecycle, code: WebSocketCloseCode.goingAway, queue: queue)
            throw mapConnectFailure(
                error, host: host, missingCertificate: missingCertificate, mismatchFingerprint: mismatchFingerprint
            )
        }
    }

    nonisolated private static func mapConnectFailure(
        _ error: Error,
        host: String,
        missingCertificate: OSAllocatedUnfairLock<Bool>,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>
    ) -> Error {
        if !Task.isCancelled, missingCertificate.withLock({ $0 }),
           case let .failed(host, message, _) = error as? WebSocketTransportError {
            return WebSocketTransportError.failed(
                host: host, message: message, diagnosticFailure: DiagnosticFailure(origin: .transport, classification: .noCertificate)
            )
        }
        return WebSocketPingSupport.mappedConnectionError(error, mismatchFingerprint: mismatchFingerprint, host: host)
    }
}

extension WebSocketConnection {
    // MARK: - Messaging

    func receive() async throws -> URLSessionWebSocketTask.Message {
        let connection = connection
        let lifecycle = lifecycle
        let queue = queue
        let host = host
        while true {
            if let event = try nextInboundEvent() {
                switch event {
                case .message(let message):
                    return message
                case .ping(let payload):
                    // Reply to daemon pings automatically; the app's own
                    // liveness pings stay explicit via sendPing().
                    Self.enqueue(Self.encodeControl(.pong, payload: payload), to: connection) { _ in }
                case .pong(let payload):
                    resolvePong(payload)
                case let .close(code, reason):
                    AppLog.connection.debug("[WebSocket] \(host): remote close code=\(code) reason=\(reason)")
                    Self.close(connection, lifecycle: lifecycle, code: Self.echoedCloseCode(code), queue: queue)
                    throw WebSocketTransportError.disconnected(host: host, code: code, reason: reason)
                }
                continue
            }
            let chunk = try await withTaskCancellationHandler {
                try await Self.read(connection, host: host)
            } onCancel: {
                Self.close(connection, lifecycle: lifecycle, code: WebSocketCloseCode.normalClosure, queue: queue)
            }
            guard let chunk else {
                // The stream ended without a close frame (RFC 6455 abnormal
                // closure).
                throw WebSocketTransportError.disconnected(
                    host: host,
                    code: Int(WebSocketCloseCode.abnormalClosure),
                    reason: "Connection closed"
                )
            }
            inbound.append(chunk)
        }
    }

    /// The next decoded event; protocol violations fail the connection with
    /// the matching close code (1002, 1007, or 1009).
    private func nextInboundEvent() throws -> InboundEvent? {
        do {
            return try inbound.nextEvent()
        } catch let error as MessageAssemblyError {
            let code: UInt16
            let reason: String
            switch error {
            case .invalidTextEncoding:
                code = WebSocketCloseCode.invalidFramePayloadData
                reason = "Invalid UTF-8 text payload"
            case .protocolViolation(let violation):
                code = violation.closeCode
                reason = "WebSocket protocol violation: \(violation)"
            }
            Self.close(connection, lifecycle: lifecycle, code: code, queue: queue)
            throw WebSocketTransportError.disconnected(host: host, code: Int(code), reason: reason)
        }
    }

    func send(_ text: String) async throws {
        try await sendPayload(Data(text.utf8), opcode: .text)
    }

    func send(_ data: Data) async throws {
        try await sendPayload(data, opcode: .binary)
    }

    /// Compresses (when negotiated and worthwhile) and writes one unfragmented
    /// message. Compression and the enqueue happen before the first
    /// suspension, so deflate context order always matches wire order.
    private func sendPayload(_ data: Data, opcode: WebSocketOpcode) async throws {
        let compressed = deflate?.compressIfWorthwhile(data)
        let frame = WebSocketFrame(opcode: opcode, payload: compressed ?? data, isCompressed: compressed != nil)
        try await Self.write(WebSocketFrameEncoder.encode(frame, maskingKey: .random()), to: connection, host: host)
    }

    func sendPing() async throws {
        let pending = WebSocketPingSupport.PendingPing(initialState: nil)
        nextPingID &+= 1
        let payload = withUnsafeBytes(of: nextPingID.bigEndian) { Data($0) }
        pendingPings[payload] = pending
        defer { pendingPings[payload] = nil }
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
        let host = host
        let frame = Self.encodeControl(.ping, payload: payload)
        try await withTaskCancellationHandler {
            try await WebSocketPingSupport.performPing(pending: pending) {
                Self.enqueue(frame, to: connection) { error in
                    guard let error else { return }
                    WebSocketPingSupport.takePending(pending)?.resume(throwing: WebSocketTransportError.failed(
                        host: host,
                        message: String(describing: error)
                    ))
                }
            }
        } onCancel: {
            WebSocketPingSupport.takePending(pending)?.resume(throwing: CancellationError())
        }
    }

    /// Completes the `sendPing()` waiting for this payload; unsolicited pongs
    /// are ignored (RFC 6455 §5.5.3).
    private func resolvePong(_ payload: Data) {
        guard let pending = pendingPings.removeValue(forKey: payload) else { return }
        WebSocketPingSupport.takePending(pending)?.resume(returning: ())
    }

    func disconnect() {
        pathObservation.stop()
        Self.close(connection, lifecycle: lifecycle, code: WebSocketCloseCode.normalClosure, queue: queue)
    }
}
