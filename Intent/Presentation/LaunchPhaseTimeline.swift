import Foundation

/// Staged delays behind the launch screens' timelines: LoadingView's intro
/// beat and ConnectingView's workspace-data poll.
enum LaunchPhaseTimeline {
    /// Sleeps for `duration`.
    static func delay(for duration: Duration) async throws {
        try? await Task.sleep(for: duration)
    }

    /// Polls `condition` every `interval` until it holds or `timeout`
    /// elapses. Returns whether the condition held before the deadline.
    static func poll(
        until condition: () -> Bool,
        timeout: Duration,
        interval: Duration
    ) async throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() && ContinuousClock.now < deadline {
            try? await Task.sleep(for: interval)
        }
        return condition()
    }
}
