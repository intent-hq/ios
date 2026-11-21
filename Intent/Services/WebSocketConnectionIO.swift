import Foundation
import Network
import os

extension WebSocketConnection {
    nonisolated struct Upgrade: Sendable {
        let deflate: PerMessageDeflateParameters?
        let leftover: Data
    }

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

    nonisolated static func write(_ data: Data, to connection: NWConnection, host: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            enqueue(data, to: connection) { error in
                continuation.resume(with: writeResult(error, host: host))
            }
        }
    }

    nonisolated static func writeWhileOpen(
        _ data: Data,
        to connection: NWConnection,
        lifecycle: Lifecycle,
        host: String
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queued = enqueueWhileOpen(data, to: connection, lifecycle: lifecycle) { error in
                continuation.resume(with: writeResult(error, host: host))
            }
            if !queued {
                continuation.resume(throwing: WebSocketTransportError.failed(host: host, message: "Connection closed"))
            }
        }
    }

    nonisolated static func enqueueWhileOpen(
        _ data: Data,
        to connection: NWConnection,
        lifecycle: Lifecycle,
        completion: @escaping @Sendable (NWError?) -> Void
    ) -> Bool {
        lifecycle.withLock { state in
            guard state == .open else { return false }
            enqueue(data, to: connection, completion: completion)
            return true
        }
    }

    nonisolated private static func writeResult(_ error: NWError?, host: String) -> Result<Void, Error> {
        guard let error else { return .success(()) }
        return .failure(WebSocketTransportError.failed(
            host: host,
            message: String(describing: error),
            diagnosticFailure: TransportDiagnosticFailure.classify(error)
        ))
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

    nonisolated static func echoedCloseCode(_ code: Int) -> UInt16 {
        guard let value = UInt16(exactly: code), WebSocketCloseCode.isSendable(value) else {
            return WebSocketCloseCode.normalClosure
        }
        return value
    }

    nonisolated static func close(
        _ connection: NWConnection,
        lifecycle: Lifecycle,
        code: UInt16,
        queue: DispatchQueue
    ) {
        connection.pathUpdateHandler = nil
        connection.viabilityUpdateHandler = nil
        let payload = Data([UInt8(code >> WebSocketFrameLayout.bitsPerByte), UInt8(truncatingIfNeeded: code)])
        let closeFrame = encodeControl(.close, payload: payload)
        let previous = lifecycle.withLock { state in
            let previous = state
            if state == .open {
                state = .closing
                enqueue(closeFrame, to: connection) { _ in connection.cancel() }
            }
            return previous
        }
        switch previous {
        case .connecting:
            connection.cancel()
            return
        case .closing:
            return
        case .open:
            break
        }
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
