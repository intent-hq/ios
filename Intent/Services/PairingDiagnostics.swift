import Foundation

nonisolated enum PairingDiagnostics {
    static func phase(
        _ stage: DiagnosticEvent.Stage,
        _ outcome: DiagnosticEvent.Outcome,
        failure: DiagnosticFailure = .none,
        store: DiagnosticStore = .shared
    ) {
        store.record(DiagnosticEvent(
            kind: .pairingPhase,
            operation: .pairingPhase,
            site: .pairing,
            stage: stage,
            outcome: outcome,
            failure: failure
        ))
    }

    static func probeResult(_ result: CertFingerprintProbe.ProbeResult, store: DiagnosticStore = .shared) {
        let failure = TransportDiagnosticFailure.probe(result)
        if case .cancelled = result {
            phase(.probe, .cancelled, store: store)
        } else {
            phase(.probe, failure == .none ? .awaitingConfirmation : .failed, failure: failure, store: store)
        }
    }

    static func invalidInput(store: DiagnosticStore = .shared) {
        phase(.input, .failed, failure: DiagnosticFailure(origin: .localOperation, classification: .invalidInput), store: store)
    }

    /// Receives closed capability/failure values, not camera errors or QR text.
    static func scanner(
        _ operation: DiagnosticOperation,
        failure: DiagnosticFailure.Classification,
        store: DiagnosticStore = .shared
    ) {
        store.record(DiagnosticEvent(
            kind: .operationFailed,
            operation: operation,
            site: .scanner,
            stage: operation == .scannerStart ? .start : .permission,
            outcome: .failed,
            failure: DiagnosticFailure(origin: .localOperation, classification: failure)
        ))
    }
}
