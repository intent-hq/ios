import Foundation

/// Staged delays behind the launch screens' timelines: LoadingView's intro
/// beat and ConnectingView's workspace-data poll. Both helpers throw
/// `CancellationError` as soon as the owning task is cancelled, so a
/// dismissed or superseded screen stops advancing its timeline and never
/// reaches the coordinator callback that follows the delay (ios#230).
enum LaunchPhaseTimeline {
    /// Sleeps for `duration`, propagating cancellation instead of swallowing
    /// it. Cancellation that lands after the sleep completed but before the
    /// caller resumes is surfaced as well, so a completed beat never advances
    /// a task that was cancelled meanwhile.
    static func delay(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
        try Task.checkCancellation()
    }

    /// Polls `condition` every `interval` until it holds or `timeout`
    /// elapses on the monotonic `ContinuousClock`. Returns whether the
    /// condition held before the deadline; throws `CancellationError` when
    /// the owning task is cancelled, without evaluating `condition` again.
    @discardableResult
    static func poll(
        until condition: () -> Bool,
        timeout: Duration,
        interval: Duration
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            try Task.checkCancellation()
            if condition() { return true }
            let now = clock.now
            guard now < deadline else { return false }
            try await clock.sleep(for: min(interval, now.duration(to: deadline)))
        }
    }
}
