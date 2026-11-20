import Foundation
import Synchronization

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

nonisolated enum DiagnosticRequestContext {
    enum Recording: Sendable {
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
    static func isConnectionLoss(_ error: any Error) -> Bool {
        let classification = failure(for: error).classification
        return classification == .connectionClosed || classification == .notConnected
    }

    static func alertMessage(for error: any Error) -> String? {
        isConnectionLoss(error) ? nil : error.localizedDescription
    }
}
