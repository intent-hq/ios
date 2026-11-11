import Foundation

/// One finite list read (ios#462): not started, running, succeeded, or failed
/// before any success. A failed refresh keeps the last success, so cached rows
/// stay on screen instead of being replaced by an error.
enum LoadPhase: Equatable {
    /// The latest read failed and none has succeeded since the last reset.
    case failed(String)
    case idle
    /// The last read succeeded at this date.
    case loaded(Date)
    /// A read is running. `lastLoadedAt` is the success still shown meanwhile.
    case loading(lastLoadedAt: Date?)
    /// A read failed after a success; the shown data stays and so does the
    /// message, until the next read starts. Only `failingVisibly` produces it.
    case refreshFailed(String, lastLoadedAt: Date)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// When the shown data last loaded successfully; nil before any success.
    var lastLoadedAt: Date? {
        switch self {
        case .loading(let date): date
        case .loaded(let date): date
        case .refreshFailed(_, let date): date
        case .idle, .failed: nil
        }
    }

    var hasLoaded: Bool { lastLoadedAt != nil }

    /// A failed first read: views show `LoadFailureView` with Retry.
    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    /// A failed refresh shown over the kept data.
    var refreshFailureMessage: String? {
        if case .refreshFailed(let message, _) = self { return message }
        return nil
    }

    var anyFailureMessage: String? { failureMessage ?? refreshFailureMessage }

    /// No data and no failure yet: views show their loading placeholder.
    var isAwaitingFirstLoad: Bool { !hasLoaded && failureMessage == nil }

    // Transitions return the next phase so stores assign only real changes:
    // an identical refetch must not invalidate observers.

    func beginning() -> Self {
        .loading(lastLoadedAt: lastLoadedAt)
    }

    /// Keeps a previous success; otherwise records the failure.
    func failing(_ error: Error) -> Self {
        lastLoadedAt.map { .loaded($0) } ?? .failed(error.localizedDescription)
    }

    /// Keeps a previous success and the message with it; otherwise records the failure.
    func failingVisibly(_ message: String) -> Self {
        lastLoadedAt.map { .refreshFailed(message, lastLoadedAt: $0) } ?? .failed(message)
    }

    /// Dismisses a shown failure without starting a read.
    func clearingFailure() -> Self {
        switch self {
        case .failed: .idle
        case .refreshFailed(_, let date): .loaded(date)
        case .idle, .loaded, .loading: self
        }
    }

    /// Ends a read that produced no result (cancelled or superseded).
    func settled() -> Self {
        guard case .loading(let date) = self else { return self }
        return date.map { .loaded($0) } ?? .idle
    }
}
