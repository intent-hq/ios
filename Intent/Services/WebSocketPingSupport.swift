import Foundation
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

    /// Installs the continuation `sendPing()` waits on, then runs `send`,
    /// which writes the ping frame. The receive path resumes the continuation
    /// when the matching pong arrives; send errors, the ping timeout, and
    /// cancellation resume it through `takePending`.
    static func performPing(pending: PendingPing, send: () -> Void) async throws {
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
            send()
        }
    }
}
