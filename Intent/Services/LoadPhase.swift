import Foundation

enum LoadPhase: Equatable {
    case failed(String)
    case idle
    case loaded(Date)
    case loading(lastLoadedAt: Date?)
    case loadingKeepingFailure(String, lastLoadedAt: Date?)
    case refreshFailed(String, lastLoadedAt: Date)

    var isLoading: Bool {
        switch self {
        case .loading, .loadingKeepingFailure: true
        case .idle, .loaded, .failed, .refreshFailed: false
        }
    }

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

    var failureMessage: String? {
        if case .failed(let message) = self { return message }
        return nil
    }

    var refreshFailureMessage: String? {
        if case .refreshFailed(let message, _) = self { return message }
        return nil
    }

    var anyFailureMessage: String? {
        switch self {
        case .failed(let message), .refreshFailed(let message, _), .loadingKeepingFailure(let message, _): message
        case .idle, .loaded, .loading: nil
        }
    }

    var isAwaitingFirstLoad: Bool { !hasLoaded && failureMessage == nil }

    func beginning() -> Self {
        .loading(lastLoadedAt: lastLoadedAt)
    }

    func beginningKeepingFailure() -> Self {
        switch self {
        case .failed(let message): .loadingKeepingFailure(message, lastLoadedAt: nil)
        case let .refreshFailed(message, date): .loadingKeepingFailure(message, lastLoadedAt: date)
        case .loadingKeepingFailure: self
        case .idle, .loaded, .loading: beginning()
        }
    }

    func failingDuringRead(_ message: String) -> Self {
        .loadingKeepingFailure(message, lastLoadedAt: lastLoadedAt)
    }

    func failing(_ error: Error) -> Self {
        lastLoadedAt.map { .loaded($0) } ?? .failed(error.localizedDescription)
    }

    func failingVisibly(_ message: String) -> Self {
        lastLoadedAt.map { .refreshFailed(message, lastLoadedAt: $0) } ?? .failed(message)
    }

    func clearingFailure() -> Self {
        switch self {
        case .failed: .idle
        case .refreshFailed(_, let date): .loaded(date)
        case .loadingKeepingFailure(_, let date): .loading(lastLoadedAt: date)
        case .idle, .loaded, .loading: self
        }
    }

    func settled() -> Self {
        switch self {
        case .loading(let date): date.map { .loaded($0) } ?? .idle
        case let .loadingKeepingFailure(message, date): Self.loading(lastLoadedAt: date).failingVisibly(message)
        case .idle, .loaded, .failed, .refreshFailed: self
        }
    }
}
