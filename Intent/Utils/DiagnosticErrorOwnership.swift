import Foundation
import Synchronization

/// In-memory provenance, never serialized. Only app-owned boundaries attach a
/// receipt; a server's domain/code/message cannot manufacture one. Copies of an
/// NSError retain the same receipt, so propagation through stores records once.
nonisolated final class DiagnosticErrorReceipt: Sendable {
    let failure: DiagnosticFailure
    private let claimed: Mutex<Bool>

    init(_ failure: DiagnosticFailure, suppressed: Bool = false) {
        self.failure = failure
        claimed = Mutex(suppressed)
    }

    func claim() -> Bool {
        claimed.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
    }
}

nonisolated enum DiagnosticErrorOwnership {
    private static let receiptKey = "IntentDiagnosticReceipt"

    /// Retains the existing error domain, code and UI text. The receipt contains
    /// only closed diagnostics and never reads that text back for classification.
    static func attaching(
        to error: NSError, failure: DiagnosticFailure, suppressed: Bool = false
    ) -> NSError {
        var info = error.userInfo
        info[receiptKey] = DiagnosticErrorReceipt(failure, suppressed: suppressed)
        return NSError(domain: error.domain, code: error.code, userInfo: info)
    }

    static func failure(for error: any Error) -> DiagnosticFailure {
        if let receipt = (error as NSError).userInfo[receiptKey] as? DiagnosticErrorReceipt {
            return receipt.failure
        }
        return TransportDiagnosticFailure.classify(error)
    }

    /// Feature owners use this for propagated request failures AND local errors.
    /// Requests already recorded at transport ingress are not recorded again.
    /// Cancellation and explicitly suppressed teardown receipts are benign.
    @discardableResult
    static func record(
        _ error: any Error,
        event: DiagnosticEvent,
        store: DiagnosticStore = .shared
    ) -> Bool {
        guard !(error is CancellationError), !Task.isCancelled else { return false }
        if let receipt = (error as NSError).userInfo[receiptKey] as? DiagnosticErrorReceipt,
           !receipt.claim() { return false }
        return store.record(event)
    }
}

/// Opt-in request ownership for an enclosing operation. Later feature producers
/// can set a closed operation/site/outcome before calling request; no protocol
/// signature changes or free-form method names enter the diagnostic channel.
nonisolated enum DiagnosticRequestContext {
    enum Recording: Sendable {
        /// The feature decides whether a rejection is benign compatibility,
        /// recovered, or terminal, then claims the receipt in its own catch.
        case deferred
        case immediate
    }

    struct Owner: Sendable {
        let operation: DiagnosticOperation
        let site: DiagnosticSite
        var outcome: DiagnosticEvent.Outcome = .failed
        var kind: DiagnosticEvent.Kind = .operationFailed
        var recording: Recording = .immediate
    }

    @TaskLocal static var owner: Owner?
}

extension DiagnosticErrorOwnership {
    /// A request that failed only because the Mac connection dropped (or was
    /// not up). Read-only mode covers these, so they never raise an alert.
    static func isConnectionLoss(_ error: any Error) -> Bool {
        let classification = failure(for: error).classification
        return classification == .connectionClosed || classification == .notConnected
    }

    /// The text for an error alert, or nil when the drop itself is the cause.
    static func alertMessage(for error: any Error) -> String? {
        isConnectionLoss(error) ? nil : error.localizedDescription
    }
}
