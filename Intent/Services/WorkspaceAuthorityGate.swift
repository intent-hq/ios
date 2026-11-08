import Foundation

/// Parks reads that need an agent's authoritative workspace while only a route
/// hint is known. Shared agent detail either resolves the workspace or fails;
/// a failure refuses later waits and owes the subscriptions a fresh read once
/// the workspace resolves.
@MainActor
final class WorkspaceAuthorityGate {
    private(set) var hasFailed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var hasWaiters: Bool { !waiters.isEmpty }

    /// Returns true when the workspace resolves, false on failure, cancellation or reset.
    func wait() async -> Bool {
        guard !Task.isCancelled, !hasFailed else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { waiters[id] = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: false)
            }
        }
    }

    func fail() {
        hasFailed = true
        release(ready: false)
    }

    /// Clears a failure without releasing waiters. Returns whether one was cleared.
    func clearFailure() -> Bool {
        defer { hasFailed = false }
        return hasFailed
    }

    func release(ready: Bool) {
        let parked = waiters.values
        waiters.removeAll()
        for waiter in parked { waiter.resume(returning: ready) }
    }

    func reset() {
        release(ready: false)
        hasFailed = false
    }
}
