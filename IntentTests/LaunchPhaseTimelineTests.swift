import Foundation
@testable import Intent
import Testing

/// ios#230: the launch screens' staged delays must honor task cancellation,
/// so a dismissed or superseded screen stops advancing its timeline and never
/// reaches the stage (the coordinator callback) that follows the delay.
struct LaunchPhaseTimelineTests {
    /// Records which timeline stages ran and how often the poll condition
    /// was evaluated.
    private final class Probe {
        var reached: [String] = []
        var polls = 0
        var started = false
    }

    // MARK: - Cancellation

    /// LoadingView: cancelling the intro beat must not fall through to
    /// `onLoadComplete`.
    @Test func cancelledDelayLeavesLaterStageUnreached() async throws {
        let probe = Probe()
        let task = Task {
            probe.started = true
            try await LaunchPhaseTimeline.delay(for: .seconds(2))
            probe.reached.append("advance")
        }
        // The task and the delay run on the main actor with this test and do
        // not suspend between `started` and the delay's sleep, so observing
        // `started` means the task is parked inside the delay.
        try await waitUntil("timeline task to enter its delay") { probe.started }
        task.cancel()
        let start = ContinuousClock.now
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        #expect(probe.reached.isEmpty)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// ConnectingView: cancelling mid-poll must finish promptly, stop
    /// evaluating the condition, and never publish connection success.
    @Test func cancelledPollStopsPromptlyAndLeavesLaterStageUnreached() async throws {
        let probe = Probe()
        let task = Task {
            let ready = try await LaunchPhaseTimeline.poll(
                until: {
                    probe.polls += 1
                    return false
                },
                timeout: .seconds(3),
                interval: .milliseconds(10)
            )
            probe.reached.append(ready ? "success" : "timeout")
        }
        try await waitUntil("timeline poll to evaluate its condition") { probe.polls > 0 }
        task.cancel()
        let start = ContinuousClock.now
        let result = await task.result
        #expect(ContinuousClock.now - start < .seconds(1))
        let pollsAtCancel = probe.polls
        try? await Task.sleep(for: .milliseconds(100))
        #expect(probe.polls == pollsAtCancel)
        #expect(probe.reached.isEmpty)
        #expect(throws: CancellationError.self) { try result.get() }
    }

    /// An attempt superseded between `connect` returning and the poll
    /// starting must not report success even when the data is already there.
    @Test func pollCancelledBeforeStartingDoesNotReportSuccess() async {
        let task = Task {
            try await LaunchPhaseTimeline.poll(
                until: { true },
                timeout: .seconds(1),
                interval: .milliseconds(10)
            )
        }
        task.cancel()
        let result = await task.result
        #expect(throws: CancellationError.self) { try result.get() }
    }

    // MARK: - Ordinary timeline

    @Test func delayCompletesWhenNotCancelled() async throws {
        let start = ContinuousClock.now
        try await LaunchPhaseTimeline.delay(for: .milliseconds(30))
        #expect(ContinuousClock.now - start >= .milliseconds(30))
    }

    @Test func pollReturnsTrueOnceConditionHolds() async throws {
        var remaining = 3
        let ready = try await LaunchPhaseTimeline.poll(
            until: {
                remaining -= 1
                return remaining <= 0
            },
            timeout: .seconds(5),
            interval: .milliseconds(5)
        )
        #expect(ready)
        #expect(remaining == 0)
    }

    @Test func pollReturnsFalseAfterTimeout() async throws {
        let start = ContinuousClock.now
        let ready = try await LaunchPhaseTimeline.poll(
            until: { false },
            timeout: .milliseconds(60),
            interval: .milliseconds(10)
        )
        let elapsed = ContinuousClock.now - start
        #expect(!ready)
        #expect(elapsed >= .milliseconds(60))
        #expect(elapsed < .seconds(2))
    }
}
