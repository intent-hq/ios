import Foundation
import Network

/// These are boundary classifiers, not string redactors. Associated hostnames,
/// fingerprints, foreign descriptions and unknown numeric codes are discarded.
nonisolated enum TransportDiagnosticFailure {
    static func classify(_ error: any Error) -> DiagnosticFailure {
        if let error = error as? NWError { return network(CertFingerprintProbe.FailureCause(error)) }
        guard let error = error as? WebSocketTransportError else {
            return DiagnosticFailure(origin: .unknown, classification: .unknown)
        }
        switch error {
        case .invalidURL: return DiagnosticFailure(origin: .transport, classification: .invalidInput)
        case .missingCertificatePin: return DiagnosticFailure(origin: .transport, classification: .missingPin)
        case .certificateMismatch, .certificateMismatches:
            return DiagnosticFailure(origin: .transport, classification: .pinMismatch)
        case .timedOut: return DiagnosticFailure(origin: .transport, classification: .requestTimeout)
        case .failed(_, _, let failure): return failure
        case .disconnected(_, let code, _):
            return DiagnosticFailure(origin: .transport, classification: .connectionClosed, code: closeCode(code))
        }
    }

    static func network(
        _ cause: CertFingerprintProbe.FailureCause, origin: DiagnosticFailure.Origin = .transport
    ) -> DiagnosticFailure {
        let code: DiagnosticFailure.Code
        switch (cause.domain, cause.code) {
        case (.posix, POSIXErrorCode.ECONNREFUSED.rawValue): code = .connectionRefused
        case (.posix, POSIXErrorCode.ECONNRESET.rawValue): code = .connectionReset
        case (.posix, POSIXErrorCode.ETIMEDOUT.rawValue): code = .timedOut
        case (.posix, POSIXErrorCode.ENETUNREACH.rawValue), (.posix, POSIXErrorCode.EHOSTUNREACH.rawValue):
            code = .unreachable
        case (.dns, _): code = .dns
        case (.tls, _): code = .tls
        default: code = .other
        }
        return DiagnosticFailure(origin: origin, classification: .transportUnknown, code: code)
    }

    static func probe(_ result: CertFingerprintProbe.ProbeResult) -> DiagnosticFailure {
        switch result {
        case .cancelled: .none
        case .fingerprint(let value): value.isEmpty
            ? DiagnosticFailure(origin: .probe, classification: .noCertificate) : .none
        case .invalidPort, .noHosts: DiagnosticFailure(origin: .probe, classification: .invalidInput)
        case .noCertificate: DiagnosticFailure(origin: .probe, classification: .noCertificate)
        case .timeout: DiagnosticFailure(origin: .probe, classification: .requestTimeout)
        case .tlsFailed(let cause), .unreachable(let cause): network(cause, origin: .probe)
        }
    }

    // RFC 6455's fixed protocol code table, not application-provided numbers.
    // swiftlint:disable no_magic_numbers
    private static func closeCode(_ code: Int) -> DiagnosticFailure.Code {
        switch code {
        case 1000: .normalClose
        case 1001: .goingAway
        case 1002: .protocolError
        case 1006: .abnormalClose
        case 1007: .invalidPayload
        case 1008: .policyViolation
        case 1009: .messageTooLarge
        case 1011: .internalError
        default: .other
        }
    }
    // swiftlint:enable no_magic_numbers
}
