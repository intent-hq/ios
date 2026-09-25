import os

/// Captures connection-queue evidence before adoption without actor-hop ordering races.
/// A general NWPathMonitor describes default routing, not this endpoint's reachability.
nonisolated final class SocketPathObservation: Sendable {
    struct Snapshot: Equatable, Sendable {
        var path: NetworkPathSnapshot?
        var isViable: Bool

        var isLost: Bool { !isViable || path?.isSatisfied == false }
    }

    private struct State {
        var snapshot: Snapshot?
        var isStopped = false
        var onUpdate: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var current: Snapshot? { state.withLock { $0.snapshot } }

    /// Called on .ready, replacing setup-time path/viability with established evidence.
    func ready(path: NetworkPathSnapshot?) {
        update { state in
            guard state.snapshot == nil else { return }
            state.snapshot = Snapshot(path: path, isViable: true)
        }
    }

    func pathChanged(_ path: NetworkPathSnapshot) {
        update { $0.snapshot?.path = path }
    }

    func viabilityChanged(_ isViable: Bool) {
        update { $0.snapshot?.isViable = isViable }
    }

    /// Atomically install then replay. Notifications read current state, not an older
    /// captured value that could arrive after a newer update on the main actor.
    func observe(_ onUpdate: @escaping @Sendable () -> Void) {
        let shouldReplay = state.withLock { state in
            guard !state.isStopped else { return false }
            state.onUpdate = onUpdate
            return state.snapshot != nil
        }
        if shouldReplay { onUpdate() }
    }

    func removeObserver() {
        state.withLock { $0.onUpdate = nil }
    }

    func stop() {
        state.withLock { state in
            state.isStopped = true
            state.snapshot = nil
            state.onUpdate = nil
        }
    }

    private func update(_ mutate: @Sendable (inout State) -> Void) {
        let callback = state.withLock { state -> (@Sendable () -> Void)? in
            guard !state.isStopped else { return nil }
            mutate(&state)
            return state.snapshot == nil ? nil : state.onUpdate
        }
        callback?()
    }
}
