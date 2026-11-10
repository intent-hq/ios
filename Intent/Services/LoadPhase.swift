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

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// When the shown data last loaded successfully; nil before any success.
    var lastLoadedAt: Date? {
        switch self {
        case .loading(let date): date
        case .loaded(let date): date
        case .idle, .failed: nil
        }
    }

    var hasLoaded: Bool { lastLoadedAt != nil }

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

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

    /// Ends a read that produced no result (cancelled or superseded).
    func settled() -> Self {
        guard case .loading(let date) = self else { return self }
        return date.map { .loaded($0) } ?? .idle
    }
}
