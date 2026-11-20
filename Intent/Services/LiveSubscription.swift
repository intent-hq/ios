import Foundation

enum LiveSubscription: Equatable {
    enum Feed: Equatable {
        case legacy
        case live
    }

    case idle
    case live(id: String?)
    case resnapshotting(id: String?, feed: Feed)
    case subscribed(id: String)

    var id: String? {
        switch self {
        case .idle: nil
        case let .subscribed(id): id
        case let .live(id): id
        case let .resnapshotting(id, _): id
        }
    }

    var isLive: Bool {
        switch self {
        case .live, .resnapshotting(_, .live): true
        case .idle, .subscribed, .resnapshotting(_, .legacy): false
        }
    }

    var isResnapshotting: Bool {
        if case .resnapshotting = self { return true }
        return false
    }

    private var feed: Feed { isLive ? .live : .legacy }

    private static func settled(id: String?, feed: Feed) -> Self {
        switch (id, feed) {
        case (nil, .legacy): .idle
        case let (id?, .legacy): .subscribed(id: id)
        case (_, .live): .live(id: id)
        }
    }

    private func replacing(id newId: String?, feed newFeed: Feed? = nil) -> Self {
        let nextFeed = newFeed ?? feed
        if isResnapshotting { return .resnapshotting(id: newId, feed: nextFeed) }
        return Self.settled(id: newId, feed: nextFeed)
    }

    mutating func acknowledge(_ newId: String) -> String? {
        let previous = id
        self = replacing(id: newId)
        return previous
    }

    mutating func applySnapshot() {
        self = replacing(id: id, feed: .live)
    }

    mutating func clearId() {
        self = replacing(id: nil)
    }

    mutating func subscribeFailed() {
        self = replacing(id: nil, feed: .legacy)
    }

    mutating func requestResnapshot() -> Bool {
        guard !isResnapshotting else { return false }
        self = .resnapshotting(id: id, feed: feed)
        return true
    }

    mutating func beginResnapshot() {
        self = .resnapshotting(id: id, feed: .legacy)
    }

    mutating func endResnapshot() {
        guard case let .resnapshotting(id, feed) = self else { return }
        self = Self.settled(id: id, feed: feed)
    }

    @discardableResult
    mutating func reset() -> String? {
        let previous = id
        self = .idle
        return previous
    }
}
