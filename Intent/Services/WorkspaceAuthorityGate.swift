import Foundation

@MainActor
final class WorkspaceAuthorityGate {
    private(set) var hasFailed = false
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]

    var hasWaiters: Bool { !waiters.isEmpty }

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
