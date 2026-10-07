import Foundation
@testable import Intent
import Testing

struct ConversationConnectionStatusTimingTests {
    @Test func phaseChangesRestartIdleDelayWithoutResettingTotalElapsed() {
        let start = Date(timeIntervalSince1970: 0)
        var timing = ConversationConnectionStatusTiming(phase: "connecting", startedAt: start)
        #expect(!timing.isDelayed(phase: "connecting", at: start.addingTimeInterval(7.99)))
        #expect(timing.isDelayed(phase: "connecting", at: start.addingTimeInterval(8)))

        // A new phase hides delay details even before the view's onChange runs.
        #expect(!timing.isDelayed(phase: "requesting", at: start.addingTimeInterval(10)))
        timing.update(phase: "requesting", at: start.addingTimeInterval(10))
        #expect(!timing.isDelayed(phase: "requesting", at: start.addingTimeInterval(17.99)))
        #expect(timing.isDelayed(phase: "requesting", at: start.addingTimeInterval(18)))
        #expect(timing.elapsed(at: start.addingTimeInterval(18)) == .seconds(18))

        // Startup phases can use the same clock independently of transcript stages.
        timing.update(phase: "starting-provider", at: start.addingTimeInterval(20))
        timing.update(phase: "starting-session", at: start.addingTimeInterval(25))
        #expect(!timing.isDelayed(phase: "starting-session", at: start.addingTimeInterval(32.99)))
        #expect(timing.isDelayed(phase: "starting-session", at: start.addingTimeInterval(33)))
        #expect(timing.elapsed(at: start.addingTimeInterval(33)) == .seconds(33))
    }

    @Test func repeatedPhaseDoesNotPostponeDelayButANewRetryAttemptDoes() {
        let start = Date(timeIntervalSince1970: 0)
        var timing = ConversationConnectionStatusTiming(
            phase: ConversationLiveTranscript.LoadingStage.retrying(attempt: 1), startedAt: start
        )
        timing.update(phase: .retrying(attempt: 1), at: start.addingTimeInterval(5))
        #expect(timing.isDelayed(phase: .retrying(attempt: 1), at: start.addingTimeInterval(8)))
        timing.update(phase: .retrying(attempt: 2), at: start.addingTimeInterval(10))
        #expect(!timing.isDelayed(phase: .retrying(attempt: 2), at: start.addingTimeInterval(17.99)))
        #expect(timing.isDelayed(phase: .retrying(attempt: 2), at: start.addingTimeInterval(18)))
        #expect(timing.elapsed(at: start.addingTimeInterval(18)) == .seconds(18))
    }

    @Test func newConversationStartsBothClocksAndElapsedCannotBeNegative() {
        let start = Date(timeIntervalSince1970: 60)
        let timing = ConversationConnectionStatusTiming(phase: "connecting", startedAt: start)
        #expect(timing.elapsed(at: start.addingTimeInterval(-1)) == .zero)
        #expect(timing.elapsed(at: start) == .zero)
        #expect(!timing.isDelayed(phase: "connecting", at: start))
        #expect(timing.isDelayed(phase: "connecting", at: start.addingTimeInterval(8)))
    }
}
