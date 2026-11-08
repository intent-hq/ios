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
        case running(Task<Void, Never>)
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
    func run(
        isCurrent: @escaping @MainActor () -> Bool,
        pass: @escaping @MainActor (_ revision: Int) async -> Void
    ) async {
        guard !Task.isCancelled else { return }
        if case .running(let task) = phase {
            await task.value
            return
        }
        let task = Task { [weak self] in
            for _ in 0..<2 {
                guard let self, !Task.isCancelled, isCurrent() else { return }
                let passRevision = revision
                await pass(passRevision)
                if passRevision == revision { return }
            }
        }
        phase = .running(task)
        await task.value
        if phase == .running(task) { phase = .idle }
    }

    /// Retires the epoch: cancels a running read and marks results stale.
    func cancel() {
        if case .running(let task) = phase { task.cancel() }
        phase = .idle
        revision &+= 1
    }
}
