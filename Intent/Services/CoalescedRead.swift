import Foundation

@MainActor
final class CoalescedRead {
    enum Phase: Equatable {
        case idle
        case scheduled
        case running(Task<Int?, Never>)
    }

    private(set) var phase: Phase = .idle
    private(set) var revision = 0

    var isRunning: Bool {
        if case .running = phase { return true }
        return false
    }

    func invalidate() -> Bool {
        revision &+= 1
        guard phase == .idle else { return false }
        phase = .scheduled
        return true
    }

    func settleScheduled() {
        if phase == .scheduled { phase = .idle }
    }

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

    func cancel() {
        if case .running(let task) = phase { task.cancel() }
        phase = .idle
        revision &+= 1
    }
}
