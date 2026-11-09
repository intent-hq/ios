import Foundation

/// A single-flight read. Invalidating while it runs earns exactly one trailing
/// pass; later invalidations stay dirty for the next explicit read, event or
/// reconnect, so a noisy feed can never loop.
@MainActor
final class CoalescedRead {
    enum Phase: Equatable {
        case idle
        /// An invalidation spawned a read that has not started yet.
        case scheduled
        /// The task yields the revision its last pass started at.
        case running(Task<Int?, Never>)
    }

    private(set) var phase: Phase = .idle
    /// Bumped by every invalidation; a pass is current while it is unchanged.
    private(set) var revision = 0

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    /// Marks the last result stale. Returns true when the caller must schedule
    /// a read, because none is scheduled or running.
    func invalidate() -> Bool {
        revision &+= 1
        guard phase == .idle else { return false }
        phase = .scheduled
        return true
    }

    /// Settles a scheduled read that ended without running its own pass.
    func settleScheduled() {
        if phase == .scheduled { phase = .idle }
    }

    /// Joins the running read, or runs `pass` once plus one trailing pass when
    /// invalidated mid-read. `isCurrent` is checked before every pass.
    ///
    /// Returns true only to the owning caller, and only when the read is still
    /// current but ended invalidated after its last pass started. Adopters that
    /// must converge under a continuous feed may start another read; the rest
    /// ignore it and stay dirty.
    @discardableResult
    func run(
        isCurrent: @escaping @MainActor () -> Bool,
        pass: @escaping @MainActor (_ revision: Int) async -> Void
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if case .running(let task) = phase {
            _ = await task.value
            return false
        }
        let task = Task { [weak self] () -> Int? in
            var lastPass: Int?
            for _ in 0..<2 {
                guard let self, !Task.isCancelled, isCurrent() else { return lastPass }
                let passRevision = revision
                lastPass = passRevision
                await pass(passRevision)
                if passRevision == revision { return lastPass }
            }
            return lastPass
        }
        phase = .running(task)
        let lastPass = await task.value
        guard phase == .running(task) else { return false }
        phase = .idle
        guard let lastPass, lastPass != revision else { return false }
        return isCurrent()
    }

    /// Retires the epoch: cancels a running read and marks results stale.
    func cancel() {
        if case .running(let task) = phase { task.cancel() }
        phase = .idle
        revision &+= 1
    }
}
