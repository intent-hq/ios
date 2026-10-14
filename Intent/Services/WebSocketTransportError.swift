import Foundation

/// One observed per-host certificate mismatch: the candidate host and the
/// fingerprint it actually presented (vs the pinned one).
nonisolated struct HostCertMismatch: Equatable, Hashable, Sendable {
    let host: String
    let fingerprint: String
}

nonisolated enum WebSocketTransportError: LocalizedError, Sendable {
    case certificateMismatch(host: String, fingerprint: String)
    /// Aggregate thrown when a host race finds no winner and at least one
    /// candidate presented a wrong certificate — carries every observed
    /// per-host mismatch instead of just the last one.
    case certificateMismatches(mismatches: [HostCertMismatch])
    case disconnected(host: String, code: Int, reason: String)
    case failed(host: String, message: String,
                diagnosticFailure: DiagnosticFailure = DiagnosticFailure(origin: .transport, classification: .transportUnknown))
    case invalidURL(host: String)
    /// The record has no trusted certificate pin, so the connection is refused
    /// before any bearer token can be sent over a socket.
    case missingCertificatePin(host: String)
    case timedOut(host: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let host):
            "Invalid WebSocket URL for \(host)"
        case .missingCertificatePin(let host):
            "No trusted certificate is saved for \(host). Re-pair this device to connect securely."
        case .timedOut(let host):
            "Connection to \(host) timed out"
        case let .failed(host, message, _):
            "Connection to \(host) failed: \(message)"
        case let .disconnected(host, code, reason):
            "Disconnected from \(host) (\(code)): \(reason)"
        case let .certificateMismatch(host, fingerprint):
            "Certificate fingerprint mismatch for \(host). Received: \(fingerprint)"
        case .certificateMismatches(let mismatches):
            "Certificate fingerprint mismatch for "
                + mismatches.map { "\($0.host) (received: \($0.fingerprint))" }
                    .joined(separator: ", ")
        }
    }

    var isCertificateMismatch: Bool {
        switch self {
        case .certificateMismatch, .certificateMismatches: true
        default: false
        }
    }

    var isMissingCertificatePin: Bool {
        if case .missingCertificatePin = self { return true }
        return false
    }

    /// Changes a single-route error's label without changing its failure details.
    /// Aggregate mismatches retain each candidate's original host.
    func relabeled(host: String) -> Self {
        switch self {
        case .certificateMismatch(_, let fingerprint):
            .certificateMismatch(host: host, fingerprint: fingerprint)
        case .invalidURL:
            .invalidURL(host: host)
        case .missingCertificatePin:
            .missingCertificatePin(host: host)
        case .timedOut:
            .timedOut(host: host)
        case let .failed(_, message, failure):
            .failed(host: host, message: message, diagnosticFailure: failure)
        case let .disconnected(_, code, reason):
            .disconnected(host: host, code: code, reason: reason)
        case .certificateMismatches:
            self
        }
    }
}
