import Foundation

/// One shared operation can outlive any caller. Cancelling a waiter resumes
/// only that caller; it never cancels the registration or another consumer.
@MainActor
final class WorkspaceStatusWaiters<Value: Sendable> {
    private var result: Value?
    private var waiters: [UUID: CheckedContinuation<Value, Never>] = [:]

    func wait(cancelledValue: Value) async -> Value {
        guard !Task.isCancelled else { return cancelledValue }
        if let result { return result }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: cancelledValue)
                } else if let result {
                    continuation.resume(returning: result)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.waiters.removeValue(forKey: id)?.resume(returning: cancelledValue)
            }
        }
    }

    func finish(_ value: Value) {
        guard result == nil else { return }
        result = value
        let pending = Array(waiters.values)
        waiters = [:]
        for waiter in pending { waiter.resume(returning: value) }
    }
}
