import Foundation
import Network
import os

extension WebSocketConnection {
    /// The result of a successful HTTP upgrade: the agreed compression (nil
    /// when uncompressed) and any frame bytes that arrived with the 101.
    nonisolated struct Upgrade: Sendable {
        let deflate: PerMessageDeflateParameters?
        let leftover: Data
    }

    /// Sends the RFC 6455 upgrade request over the ready TCP/TLS stream and
    /// validates the server's 101 response.
    nonisolated static func performUpgrade(
        _ connection: NWConnection,
        url: URL,
        token: String,
        offersCompression: Bool,
        host: String
    ) async throws -> Upgrade {
        let key = WebSocketHandshake.makeKey()
        let request = WebSocketHandshake.request(
            url: url,
            key: key,
            headers: additionalHeaders(token: token),
            extensionOffer: offersCompression ? PerMessageDeflateParameters.offer : nil
        )
        try await write(request, to: connection, host: host)
        var buffer = Data()
        do {
            while true {
                guard let chunk = try await read(connection, host: host) else {
                    throw WebSocketTransportError.failed(host: host, message: "Handshake ended before the socket opened")
                }
                buffer.append(chunk)
                guard let parsed = try WebSocketHandshake.parseResponse(buffer) else { continue }
                let deflate = try WebSocketHandshake.validate(parsed.response, key: key, offeredDeflate: offersCompression)
                return Upgrade(deflate: deflate, leftover: buffer.dropFirst(parsed.headerSize))
            }
        } catch let error as WebSocketHandshakeError {
            AppLog.connection.error("[WebSocket] \(host): upgrade rejected (\(String(describing: error)))")
            throw WebSocketTransportError.failed(
                host: host,
                message: upgradeFailureMessage(error),
                diagnosticFailure: DiagnosticFailure(
                    origin: .transport,
                    classification: error.isHTTPStatus ? .httpFailure : .malformedResponse
                )
            )
        }
    }

    nonisolated private static func upgradeFailureMessage(_ error: WebSocketHandshakeError) -> String {
        switch error {
        case .unexpectedStatus(let status): "WebSocket upgrade failed with HTTP \(status)"
        case .invalidExtensions: "WebSocket upgrade negotiated an unsupported extension"
        case .invalidAccept, .malformedResponse, .missingUpgrade, .responseTooLarge: "Invalid WebSocket upgrade response"
        }
    }

    // MARK: - Raw stream I/O

    /// Reads the next available bytes; nil when the peer ended the stream.
    nonisolated static func read(_ connection: NWConnection, host: String) async throws -> Data? {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: readChunkSize) { content, _, isComplete, error in
                if let error {
                    continuation.resume(throwing: WebSocketTransportError.failed(
                        host: host,
                        message: String(describing: error),
                        diagnosticFailure: TransportDiagnosticFailure.classify(error)
                    ))
                } else if let content, !content.isEmpty {
                    continuation.resume(returning: content)
                } else if isComplete {
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: Data())
                }
            }
        }
    }

    /// Enqueues `data` and waits until Network.framework has processed it.
    /// The enqueue happens synchronously, before the caller suspends.
    nonisolated static func write(_ data: Data, to connection: NWConnection, host: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(data, to: connection) { error in
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
        }
    }

    nonisolated static func enqueue(
        _ data: Data,
        to connection: NWConnection,
        completion: @escaping @Sendable (NWError?) -> Void
    ) {
        connection.send(content: data, completion: .contentProcessed(completion))
    }

    nonisolated static func encodeControl(_ opcode: WebSocketOpcode, payload: Data = Data()) -> Data {
        WebSocketFrameEncoder.encode(WebSocketFrame(opcode: opcode, payload: payload), maskingKey: .random())
    }

    /// The status to answer a peer's close with (RFC 6455 §5.5.1): its own
    /// code when that code may be sent on the wire, otherwise 1000.
    nonisolated static func echoedCloseCode(_ code: Int) -> UInt16 {
        let reserved: Set<UInt16> = [WebSocketCloseCode.missingStatus, WebSocketCloseCode.abnormalClosure, WebSocketCloseCode.tlsHandshake]
        guard let value = UInt16(exactly: code),
              (WebSocketCloseCode.normalClosure...WebSocketCloseCode.maximumApplication).contains(value),
              !reserved.contains(value) else {
            return WebSocketCloseCode.normalClosure
        }
        return value
    }

    /// Sends a websocket close frame (once, when the socket opened) and
    /// cancels the underlying connection. Safe to call repeatedly and from any
    /// context: once the connection is cancelled, further sends complete with
    /// an error and cancel() is idempotent.
    nonisolated static func close(
        _ connection: NWConnection,
        lifecycle: Lifecycle,
        code: UInt16,
        queue: DispatchQueue
    ) {
        connection.pathUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        let previous = lifecycle.withLock { state in
            defer { if state == .open { state = .closing } }
            return state
        }
        switch previous {
        case .connecting:
            connection.cancel()
            return
        case .closing:
            // A close frame is already in flight with its fallback cancel.
            return
        case .open:
            break
        }
        let payload = Data([UInt8(code >> WebSocketFrameLayout.bitsPerByte), UInt8(truncatingIfNeeded: code)])
        enqueue(encodeControl(.close, payload: payload), to: connection) { _ in connection.cancel() }
        // An unresponsive peer or dead path can leave the close-frame send
        // pending forever; guarantee teardown with a fallback cancel after a
        // grace period (cancel() is idempotent).
        queue.asyncAfter(
            deadline: .now() + Constants.WebSocket.closeCancellationGracePeriod
        ) { connection.cancel() }
    }
}

extension WebSocketHandshakeError {
    nonisolated var isHTTPStatus: Bool {
        if case .unexpectedStatus = self { return true }
        return false
    }
}
