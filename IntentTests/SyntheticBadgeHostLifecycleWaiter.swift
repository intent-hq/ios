import Foundation

@MainActor
final class SyntheticBadgeHostLifecycleWaiter: NSObject {
    enum Event: String, Hashable {
        case didAppear
        case didDisappear
    }

    enum WaitError: Error, Equatable {
        case concurrentWait
        case timedOut(Event)
    }

    private var continuation: CheckedContinuation<Void, any Error>?
    private var expectedEvent: Event?
    private var receivedEvents: Set<Event> = []
    private var timer: Timer?
    private let diagnostics: SyntheticBadgeHostTrace?

    init(diagnostics: SyntheticBadgeHostTrace? = nil) {
        self.diagnostics = diagnostics
        super.init()
    }

    func wait(
        for event: Event,
        timeout: TimeInterval,
        honoringCancellation: Bool,
        trigger: () -> Void
    ) async throws {
        guard !receivedEvents.contains(event) else { return }
        guard continuation == nil else { throw WaitError.concurrentWait }
        if honoringCancellation {
            try await withTaskCancellationHandler {
                try await installWait(for: event, timeout: timeout, trigger: trigger)
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelWait(for: event)
                }
            }
        } else {
            try await installWait(for: event, timeout: timeout, trigger: trigger)
        }
    }

    func receive(_ event: Event) {
        diagnostics?.record("wait.receive", fields: [
            "event": event.rawValue,
            "expected": expectedEvent?.rawValue ?? "none",
            "hasContinuation": String(continuation != nil)
        ])
        receivedEvents.insert(event)
        guard expectedEvent == event else { return }
        finish(with: .success(()))
    }

    private func installWait(
        for event: Event,
        timeout: TimeInterval,
        trigger: () -> Void
    ) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            guard self.continuation == nil else {
                continuation.resume(throwing: WaitError.concurrentWait)
                return
            }
            self.continuation = continuation
            expectedEvent = event
            diagnostics?.record("wait.install", fields: ["event": event.rawValue, "timeout": String(timeout)])
            let timer = Timer(
                timeInterval: timeout,
                target: self,
                selector: #selector(timeoutFired),
                userInfo: nil,
                repeats: false
            )
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
            diagnostics?.record("timer.armed", fields: [
                "event": event.rawValue,
                "fireDate": String(timer.fireDate.timeIntervalSince1970)
            ])
            diagnostics?.record("trigger.begin", fields: ["event": event.rawValue])
            trigger()
            diagnostics?.record("trigger.return", fields: ["event": event.rawValue])
        }
    }

    private func cancelWait(for event: Event) {
        guard expectedEvent == event else { return }
        finish(with: .failure(CancellationError()))
    }

    @objc private func timeoutFired() {
        diagnostics?.record("timer.fire", fields: ["expected": expectedEvent?.rawValue ?? "none"])
        guard let expectedEvent else { return }
        finish(with: .failure(WaitError.timedOut(expectedEvent)))
    }

    private func finish(with result: Result<Void, any Error>) {
        guard let continuation else { return }
        let outcome: String
        switch result {
        case .success: outcome = "success"
        case .failure(let error): outcome = String(describing: error)
        }
        diagnostics?.record("wait.finish", fields: ["event": expectedEvent?.rawValue ?? "none", "outcome": outcome])
        self.continuation = nil
        expectedEvent = nil
        timer?.invalidate()
        timer = nil
        continuation.resume(with: result)
    }
}
