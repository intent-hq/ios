import Foundation

/// Shared by every detail consumer on a backend, including route validation.
/// A cancelled transport keeps its slot until it really returns, so a late
/// reply cannot temporarily push the number of wire requests above the limit.
@MainActor
final class AgentDetailRequestLimiter {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var active = 0
    private var waiters: [Waiter] = []
    private let limit = 4

    func acquire() async throws {
        try Task.checkCancellation()
        if active < limit {
            active += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
        // The caller releases even when cancellation raced the grant.
    }

    func release() {
        guard !waiters.isEmpty else { active -= 1; return }
        waiters.removeFirst().continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}
