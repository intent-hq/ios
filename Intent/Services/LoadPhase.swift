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
    /// A read is running and the last failure stays on screen until it ends
    /// (Retry or an event refresh after a failure). Only `beginningKeepingFailure`
    /// and `failingDuringRead` produce it; the read ending restores the failure.
    case loadingKeepingFailure(String, lastLoadedAt: Date?)
    /// A read failed after a success; the shown data stays and so does the
    /// message, until the next read starts. Only `failingVisibly` produces it.
    case refreshFailed(String, lastLoadedAt: Date)

    var isLoading: Bool {
        switch self {
        case .loading, .loadingKeepingFailure: true
        case .idle, .loaded, .failed, .refreshFailed: false
        }
    }

    /// When the shown data last loaded successfully; nil before any success.
    var lastLoadedAt: Date? {
        switch self {
        case .loading(let date): date
        case .loadingKeepingFailure(_, let date): date
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

    /// Any failure on screen, including one kept while a read runs.
    var anyFailureMessage: String? {
        switch self {
        case .failed(let message), .refreshFailed(let message, _), .loadingKeepingFailure(let message, _): message
        case .idle, .loaded, .loading: nil
        }
    }

    /// No data and no failure yet: views show their loading placeholder.
    var isAwaitingFirstLoad: Bool { !hasLoaded && failureMessage == nil }

    // Transitions return the next phase so stores assign only real changes:
    // an identical refetch must not invalidate observers.

    func beginning() -> Self {
        .loading(lastLoadedAt: lastLoadedAt)
    }

    /// Starts a read that leaves a shown failure on screen until the read ends.
    func beginningKeepingFailure() -> Self {
        switch self {
        case .failed(let message): .loadingKeepingFailure(message, lastLoadedAt: nil)
        case let .refreshFailed(message, date): .loadingKeepingFailure(message, lastLoadedAt: date)
        case .loadingKeepingFailure: self
        case .idle, .loaded, .loading: beginning()
        }
    }

    /// Records a failure while the read keeps running (a pass with a trailing
    /// pass, or a page that keeps loading); the read ending shows it.
    func failingDuringRead(_ message: String) -> Self {
        .loadingKeepingFailure(message, lastLoadedAt: lastLoadedAt)
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
        case .loadingKeepingFailure(_, let date): .loading(lastLoadedAt: date)
        case .idle, .loaded, .loading: self
        }
    }

    /// Ends a read that produced no result (cancelled or superseded). A kept failure stays.
    func settled() -> Self {
        switch self {
        case .loading(let date): date.map { .loaded($0) } ?? .idle
        case let .loadingKeepingFailure(message, date): Self.loading(lastLoadedAt: date).failingVisibly(message)
        case .idle, .loaded, .failed, .refreshFailed: self
        }
    }
}
