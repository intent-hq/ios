import Foundation
import Network
import os

nonisolated enum WebSocketPingSupport {
    typealias PendingPing = OSAllocatedUnfairLock<CheckedContinuation<Void, Error>?>

    static func mappedConnectionError(
        _ error: Error,
        mismatchFingerprint: OSAllocatedUnfairLock<String?>,
        host: String
    ) -> Error {
        if let fingerprint = mismatchFingerprint.withLock({ $0 }) {
            return WebSocketTransportError.certificateMismatch(
                host: host,
                fingerprint: fingerprint
            )
        }
        if let transportError = error as? WebSocketTransportError {
            return transportError
        }
        if error is CancellationError {
            return error
        }
        return WebSocketTransportError.failed(host: host, message: error.localizedDescription)
    }

    static func takePending(_ pending: PendingPing) -> CheckedContinuation<Void, Error>? {
        pending.withLock { state in
            defer { state = nil }
            return state
        }
    }

    private static func pingMetadata(
        pending: PendingPing,
        queue: DispatchQueue,
        host: String
    ) -> NWProtocolWebSocket.Metadata {
        let metadata = NWProtocolWebSocket.Metadata(opcode: .ping)
        metadata.setPongHandler(queue) { error in
            let continuation = takePending(pending)
            if let error {
                continuation?.resume(throwing: WebSocketTransportError.failed(
                    host: host,
                    message: String(describing: error)
                ))
            } else {
                continuation?.resume(returning: ())
            }
        }
        return metadata
    }

    private static func sendPingFrame(
        connection: NWConnection,
        metadata: NWProtocolWebSocket.Metadata,
        pending: PendingPing,
        host: String
    ) {
        let context = NWConnection.ContentContext(identifier: "ping", metadata: [metadata])
        connection.send(
            content: nil,
            contentContext: context,
            isComplete: true,
            completion: .contentProcessed { error in
                guard let error else { return }
                takePending(pending)?.resume(throwing: WebSocketTransportError.failed(
                    host: host,
                    message: String(describing: error)
                ))
            }
        )
    }

    static func performPing(
        connection: NWConnection,
        pending: PendingPing,
        queue: DispatchQueue,
        host: String
    ) async throws {
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
            sendPingFrame(
                connection: connection,
                metadata: pingMetadata(pending: pending, queue: queue, host: host),
                pending: pending,
                host: host
            )
        }
    }
}
