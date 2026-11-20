import os

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
