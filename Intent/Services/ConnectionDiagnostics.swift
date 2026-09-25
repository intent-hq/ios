import Foundation

extension ConnectionManager {
    func recordConnectionLoss(cause: DiagnosticEvent.Context, failure: DiagnosticFailure) {
        diagnostics.record(DiagnosticEvent(
            kind: .connectionTransition,
            operation: .connectionTransition,
            site: .connectionManager,
            stage: .active,
            outcome: .retrying,
            failure: failure,
            context: cause
        ))
    }

    func recordConnectionAttempt(
        _ outcome: DiagnosticEvent.Outcome,
        failure: DiagnosticFailure = .none,
        context: DiagnosticEvent.Context = .unknown,
        scope: DiagnosticStore.Scope? = nil
    ) {
        diagnostics.record(
            DiagnosticEvent(
                kind: .connectionAttempt,
                operation: .connectionAttempt,
                site: .connectionManager,
                stage: .connect,
                outcome: outcome,
                failure: failure,
                context: context
            ),
            scope: scope
        )
    }

    func recordMalformedFrame(from origin: WebSocketConnection? = nil) {
        if let origin, socket !== origin { return }
        diagnostics.record(DiagnosticEvent(
            kind: .operationFailed,
            operation: .protocolInboundJSON,
            site: .connectionManager,
            stage: .decode,
            outcome: .failed,
            failure: DiagnosticFailure(origin: .transport, classification: .malformedResponse)
        ))
    }
}

/// Caller-supplied context is a closed enum, never inferred from credentials or
/// backend IDs. Unannotated connection entry points honestly remain unknown.
nonisolated enum DiagnosticConnectContext {
    @TaskLocal static var origin: DiagnosticEvent.Context = .unknown
}
