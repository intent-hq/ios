import Foundation
import Observation

@MainActor
@Observable
final class DiagnosticExportModel {
    private(set) var preview: DiagnosticPreview?
    private(set) var isWorking = false
    private(set) var notice: LocalizedStringResource?
    var share: DiagnosticShareLease?
    private let store: DiagnosticStore
    @ObservationIgnored private var work: Task<Void, Never>?

    init(store: DiagnosticStore = .shared) { self.store = store }

    func refresh() {
        guard !isWorking, share == nil else { return }
        start { model in
            model.preview = nil
            try await model.loadPreview()
        }
    }

    func shareZIP() {
        guard !isWorking, share == nil, let snapshot = preview?.snapshot else { return }
        start { model in
            switch await model.store.prepareExport(reviewing: snapshot) {
            case .ready(let report):
                let lease = DiagnosticShareLease(report: report, store: model.store)
                guard !Task.isCancelled else { _ = await lease.finish(); return }
                model.share = lease
            case .needsReview(let updated):
                model.preview = nil
                let value = try await DiagnosticPreview.make(updated)
                try Task.checkCancellation()
                model.preview = value
                model.notice = "Logs expired or were cleared. Review the refreshed preview, then choose Share ZIP again."
            case .unavailable:
                guard !Task.isCancelled else { return }
                model.notice = "Could not prepare the ZIP. Close any other log share sheet, then try again."
            }
        }
    }

    /// Only the confirmed destructive action calls this; it never touches
    /// saved connections, conversations, or copies already shared elsewhere.
    func clearHistory() {
        guard !isWorking, share == nil else { return }
        start { model in
            model.preview = nil
            let cleared = await model.store.clearHistory()
            try await model.loadPreview()
            model.notice = cleared
                ? "Local log history cleared. New events can still be recorded."
                : "Could not confirm all local log files were removed. Try Clear again."
        }
    }

    func sharingFinished(id: UUID, failed: Bool, cleaned: Bool) {
        guard share?.id == id else { return }
        share = nil
        if !cleaned {
            notice = "Sharing ended, but temporary log files could not be removed. Try Clear again."
        } else if failed {
            notice = "The system could not share the ZIP. You can try again."
        }
    }

    func cancelPreparation() { work?.cancel() }

    func refreshIfExpired() {
        if let preview, preview.snapshot.expiresAt <= Date() { refresh() }
    }

    /// SwiftUI owns/cancels this wait. Expiry also gets rechecked by the writer
    /// at Share time (including expiry during ZIP preparation).
    func refreshWhenExpired() async {
        guard let deadline = preview?.snapshot.expiresAt else { return }
        let delay = max(0, deadline.timeIntervalSinceNow)
        do {
            try await Task.sleep(for: .seconds(delay))
            try Task.checkCancellation()
            refresh()
        } catch { /* View disappeared or a newer preview replaced this one. */ }
    }

    func waitForWork() async { await work?.value }

    private func loadPreview() async throws {
        let snapshot = await store.snapshot()
        let value = try await DiagnosticPreview.make(snapshot)
        try Task.checkCancellation()
        preview = value
    }

    private func start(_ operation: @escaping @MainActor (DiagnosticExportModel) async throws -> Void) {
        isWorking = true
        notice = nil
        work = Task { [weak self] in
            guard let self else { return }
            defer { isWorking = false }
            do {
                try Task.checkCancellation()
                try await operation(self)
            } catch is CancellationError {
                // Dismissal never opens a late share sheet or shows a failure.
            } catch {
                notice = "Could not prepare the log preview. Try Refresh."
            }
        }
    }

    isolated deinit { work?.cancel() }
}