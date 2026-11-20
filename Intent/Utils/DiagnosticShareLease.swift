import Foundation
import Synchronization

nonisolated enum DiagnosticExportResult: Sendable {
    case needsReview(DiagnosticSnapshot)
    case ready(DiagnosticReport)
    case unavailable
}

nonisolated final class DiagnosticShareLease: Sendable, Identifiable {
    let id = UUID()
    let report: DiagnosticReport
    private let store: DiagnosticStore
    private let finished = Mutex(false)

    init(report: DiagnosticReport, store: DiagnosticStore) {
        self.report = report
        self.store = store
    }

    @discardableResult
    func finish() async -> Bool {
        let shouldFinish = finished.withLock { value in
            guard !value else { return false }
            value = true
            return true
        }
        guard shouldFinish else { return true }
        return await store.endReport(report)
    }

    deinit {
        guard !finished.withLock({ $0 }) else { return }
        let store = store
        let report = report
        Task.detached(priority: .utility) { _ = await store.endReport(report) }
    }
}
