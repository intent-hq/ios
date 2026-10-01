import Foundation

nonisolated struct WorkspaceSearchPlacement: Equatable, Sendable {
    var frame: CGRect
    var isSearching: Bool
}

nonisolated struct WorkspaceSearchMotion {
    struct Update {
        var revision: Int
        var animated: Bool
    }

    private(set) var placement: WorkspaceSearchPlacement?
    private(set) var isAnimating = false
    private(set) var revision = 0

    mutating func update(_ next: WorkspaceSearchPlacement, isSearching: Bool, reduceMotion: Bool) -> Update? {
        guard next.isSearching == isSearching, !next.frame.isEmpty, next != placement else { return nil }
        isAnimating = !reduceMotion && placement != nil && (
            isSearching || isAnimating || placement?.isSearching != next.isSearching
        )
        placement = next
        revision += 1
        return Update(revision: revision, animated: isAnimating)
    }

    mutating func complete(revision completedRevision: Int) {
        guard completedRevision == revision else { return }
        isAnimating = false
    }
}
