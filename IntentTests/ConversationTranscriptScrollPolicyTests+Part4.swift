import Foundation
@testable import Intent
import Testing
import UIKit

// Geometry regression values intentionally mirror the observed scroll offsets.
// swiftlint:disable function_body_length no_magic_numbers number_separator trailing_newline

extension ConversationTranscriptScrollPolicyTests {
    typealias RecoveryStep = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryStep

    func recovery(
        _ geometry: ViewportGeometry?,
        previous: ViewportGeometry?? = nil,
        isEndRealized: Bool = false,
        isInteracting: Bool = false,
        isFollowing: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false,
        correctionsLeft: Int = 2,
        correctionsSpent: Int = 0,
        timedOut: Bool = false
    ) -> RecoveryStep {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryStep(
            geometry: geometry,
            previous: previous ?? geometry,
            isEndRealized: isEndRealized,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            correctionsLeft: correctionsLeft,
            correctionsSpent: correctionsSpent,
            timedOut: timedOut,
            atBottomThreshold: 50,
            landingTolerance: 1
        )
    }

    /// A following viewport at the bottom with no realized end row is paged
    /// up one viewport and followed back to the end (#338).
    @Test func blankViewportAtTheBottomIsPagedUpAndFollowedBack() {
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000)) == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_299.5, contentHeight: 3_000)) == .recover(pageOffsetY: 1_599.5))
        #expect(recovery(geometry(offsetY: 2_340, contentHeight: 3_000)) == .recover(pageOffsetY: 1_640))
        #expect(recovery(geometry(offsetY: 300)) == .recover(pageOffsetY: 0))
        #expect(recovery(geometry(offsetY: 50, contentHeight: 750, topInset: 59)) == .recover(pageOffsetY: -59))
    }

    /// A first short rest inside the bottom band follows once; an unchanged
    /// geometry after that escalates to paging up.
    @Test func shortRestInsideTheBandIsFollowedOnceThenPagedUp() {
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000)) == .followToEnd)
        #expect(recovery(geometry(offsetY: 2_251, contentHeight: 3_000)) == .followToEnd)
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsSpent: 1)
            == .recover(pageOffsetY: 1_570))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000), correctionsSpent: 1)
            == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsLeft: 0) == .giveUp)
    }

    @Test func realizedEndRowNeedsNoRecovery() {
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true) == .none)
        #expect(recovery(geometry(offsetY: 270), isEndRealized: true) == .none)
        #expect(recovery(geometry(offsetY: 600), isEndRealized: true) == .none)
        #expect(recovery(nil, isEndRealized: true) == .none)
    }

    /// Geometry already owned by a clamp or growth re-pin is waited out, while
    /// content shorter than the viewport needs no recovery.
    @Test func recoveryWaitsOutGeometriesOtherPathsOwn() {
        #expect(recovery(geometry(offsetY: 351)) == .settling)
        #expect(recovery(geometry(offsetY: 600)) == .settling)
        #expect(recovery(geometry(offsetY: 249)) == .settling)
        #expect(recovery(geometry(offsetY: 0)) == .settling)
        #expect(recovery(geometry(offsetY: 0), timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 0, contentHeight: 400)) == .none)
        #expect(recovery(geometry(offsetY: 0, contentHeight: 650, containerHeight: 780)) == .none)
        #expect(recovery(geometry(offsetY: 0, contentHeight: 650, containerHeight: 780, topInset: 150))
            == .settling)
    }

    @Test func recoveryWaitsForRestAndForGesturesAndFollows() {
        #expect(recovery(nil) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: .some(nil)) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 250)) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 300, bottomInset: 20)) == .settling)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true) == .settling)
        #expect(recovery(geometry(offsetY: 300), isFollowing: true) == .settling)
    }

    @Test func recoveryIsBoundedAndIgnoresNonFollowingViewports() {
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 1) == .recover(pageOffsetY: 0))
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 0) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), timedOut: true) == .giveUp)
        #expect(recovery(nil, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true) == .none)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, timedOut: true) == .none)
        #expect(recovery(geometry(offsetY: 300), hasInitiallyScrolled: false) == .none)
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true, correctionsLeft: 0) == .none)
        let rounds = Double(Constants.Conversation.Transcript.followLandingRetries + 1)
        let roundMilliseconds = Double(3 * Constants.Conversation.Transcript.pastEndSettleMilliseconds)
        #expect(rounds * roundMilliseconds < Double(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds))
    }

    func mayFollowBack(
        isInteracting: Bool = false,
        userIsScrolledAway: Bool = false,
        isFollowing: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack(
            isInteracting: isInteracting,
            userIsScrolledAway: userIsScrolledAway,
            isFollowing: isFollowing
        )
    }

    @Test func pagedUpRecoveryYieldsToAGestureOrAFollowThatClaimedTheViewport() {
        #expect(mayFollowBack())
        #expect(!mayFollowBack(isInteracting: true))
        #expect(!mayFollowBack(userIsScrolledAway: true))
        #expect(!mayFollowBack(isFollowing: true))
        #expect(!mayFollowBack(isInteracting: true, userIsScrolledAway: true, isFollowing: true))
        #expect(ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: true,
            isFollowing: true
        ))
        #expect(!ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: false,
            isFollowing: true
        ))
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, correctionsSpent: 1) == .settling)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, correctionsSpent: 1) == .none)
        #expect(recovery(geometry(offsetY: 300), isFollowing: true, correctionsSpent: 1) == .settling)
    }

    typealias RecoveryDrain = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryDrain

    func drain(_ outcome: RecoveryStep, isFollowing: Bool = false) -> RecoveryDrain {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryDrain(
            outcome: outcome,
            isFollowing: isFollowing
        )
    }

    @Test func recoveryDrainReplaysTheEdgeTheCorrectionSuppressed() {
        #expect(!transition(current: false, distanceToBottom: 120, isInteracting: false))
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(recovery(geometry(offsetY: 180), isEndRealized: true, correctionsSpent: 1) == .none)
        #expect(drain(.none) == .replayEdge)
        #expect(!transition(current: false, distanceToBottom: 120, isInteracting: false))
        #expect(rePinAfterGrowth(isFollowing: false))
        #expect(drain(.yieldToUser) == .replayEdge)
        #expect(transition(current: false, distanceToBottom: 120, isInteracting: true))
        #expect(!rePinAfterGrowth(isInteracting: true))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
        #expect(drain(.yieldToUser, isFollowing: true) == .replayEdge)
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(!transition(current: false, distanceToBottom: 10, isInteracting: false))
        #expect(!rePinAfterGrowth(geometryAway: false))
        #expect(recoveryReport(.yieldToUser, corrections: 1).reason == .yieldedToUser)
    }

    @Test func recoveryGiveUpShowsGoToEndInsteadOfRePinningBlind() {
        #expect(recovery(geometry(offsetY: 260), correctionsLeft: 0, correctionsSpent: 2) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), correctionsSpent: 2, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, timedOut: true) == .giveUp)
        #expect(drain(.giveUp) == .showGoToEnd)
        #expect(!transition(current: false, distanceToBottom: 40, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 0, isInteracting: false))
        #expect(rePinAfterGrowth(isFollowing: false))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(goToEndRequested: true))
        #expect(ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: true,
            isEndRealized: false
        ))
        #expect(drain(.giveUp, isFollowing: true) == .deferToFollow)
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(recoveryReport(.giveUp, corrections: 2).reason == .gaveUp)
    }

    @Test func deferredGiveUpShowsGoToEndWhenTheFollowIsDropped() {
        let policy = ConversationTranscriptScrollPolicy.self
        #expect(drain(.giveUp, isFollowing: true) == .deferToFollow)
        let dropped = executeFollow(distanceToBottom: 120)
        #expect(!dropped)
        #expect(!policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: dropped, isEndRealized: false))
        #expect(!transition(
            current: false,
            distanceToBottom: 120,
            isInteracting: false,
            isEndRealized: false
        ))
        #expect(rePinAfterGrowth(isFollowing: false))
        #expect(policy.shouldShowGoToEndAfterFollow(
            executed: dropped,
            isEndRealized: false,
            giveUpDeferred: true
        ))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
        let executed = executeFollow(distanceToBottom: 30)
        #expect(executed)
        #expect(!policy.shouldShowGoToEndAfterFollow(
            executed: executed,
            isEndRealized: false,
            giveUpDeferred: true
        ))
        #expect(policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: executed, isEndRealized: false))
        let yielded = executeFollow(forced: true, distanceToBottom: 0, isInteracting: true)
        #expect(!yielded)
        #expect(policy.shouldShowGoToEndAfterFollow(
            executed: yielded,
            isEndRealized: false,
            giveUpDeferred: true
        ))
        #expect(policy.shouldShowGoToEndAfterFollow(
            executed: false,
            isEndRealized: false,
            giveUpDeferred: true
        ))
        #expect(!policy.shouldShowGoToEndAfterFollow(
            executed: false,
            isEndRealized: true,
            giveUpDeferred: true
        ))
        #expect(!policy.shouldShowGoToEndAfterFollow(
            executed: false,
            isEndRealized: false,
            giveUpDeferred: false
        ))
        #expect(transition(
            current: true,
            distanceToBottom: 0,
            isInteracting: false,
            isEndRealized: false
        ))
        #expect(!transition(
            current: true,
            distanceToBottom: 0,
            isInteracting: false,
            isEndRealized: true
        ))
    }

    @Test func followDrainingOverAnUnrealizedEndRowArmsTheRecovery() {
        let policy = ConversationTranscriptScrollPolicy.self
        #expect(policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: true, isEndRealized: false))
        #expect(!policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: true, isEndRealized: true))
        #expect(!policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: false, isEndRealized: false))
        #expect(!policy.shouldArmUnrealizedEndRecoveryAfterFollow(executed: false, isEndRealized: true))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000)) == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000), isEndRealized: true) == .none)
    }

    /// The report of a transcript with one episode armed, resolved on
    /// `outcome` (nil: still running) with the end row realized by default.
    private func recoveryReport(
        _ outcome: RecoveryStep?,
        corrections: Int = 0,
        episodes: Int = 1,
        endRealized: Bool = true,
        cancelled: Bool = false
    ) -> ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryReport(
            outcome: outcome,
            corrections: corrections,
            episodes: episodes,
            endRealized: endRealized,
            cancelled: cancelled
        )
    }

    /// `recovered` needs a correction spent and the end row realized at the
    /// finish; a `.none` that spent nothing is `noCorrectionNeeded`, one over
    /// a still unrealized end row is `unverified` (neither recovered nor a
    /// give-up: the budget was not spent and Go to End is not shown).
    @Test func recoveryReportLabelsRecoveredOnlyWithACorrectionAndTheEndRealized() {
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: true).reason == .recovered)
        #expect(recoveryReport(RecoveryStep.none, corrections: 3, endRealized: true).reason == .recovered)
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: false).reason == .unverified)
        #expect(recoveryReport(RecoveryStep.none, corrections: 0, endRealized: true).reason == .noCorrectionNeeded)
        #expect(recoveryReport(RecoveryStep.none, corrections: 0, endRealized: false).reason == .noCorrectionNeeded)
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: false).reason != .recovered)
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: false).reason != .gaveUp)
        let report = recoveryReport(RecoveryStep.none, corrections: 2, episodes: 3, endRealized: true)
        #expect(report == ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport(
            reason: .recovered,
            corrections: 2,
            episodes: 3,
            endRealized: true
        ))
    }

    /// An abandoned episode is never `recovered`: a give-up is `gaveUp`, a
    /// yield is `yieldedToUser`, and a cancelled task is `cancelled`
    /// whatever step it last took, a `.none` included.
    @Test func recoveryReportNeverLabelsAnAbandonedEpisodeRecovered() {
        for corrections in [0, 1, 3] {
            for endRealized in [false, true] {
                #expect(recoveryReport(.giveUp, corrections: corrections, endRealized: endRealized).reason == .gaveUp)
                #expect(recoveryReport(.yieldToUser, corrections: corrections, endRealized: endRealized).reason == .yieldedToUser)
                #expect(recoveryReport(nil, corrections: corrections, endRealized: endRealized, cancelled: true).reason == .cancelled)
                #expect(recoveryReport(
                    .recover(pageOffsetY: 0),
                    corrections: corrections,
                    endRealized: endRealized,
                    cancelled: true
                ).reason == .cancelled)
            }
        }
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: true, cancelled: true).reason == .cancelled)
        #expect(recoveryReport(.giveUp, corrections: 1, endRealized: true, cancelled: true).reason == .cancelled)
    }

    /// No episode armed is `notAttempted` whatever else is handed; an armed
    /// episode without a resolution (no outcome, or a step the loop
    /// continues from) is `recovering`.
    @Test func recoveryReportDistinguishesNotAttemptedFromInFlight() {
        #expect(recoveryReport(nil, episodes: 0, endRealized: false).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 0, endRealized: true).reason == .notAttempted)
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, episodes: 0).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 0, cancelled: true).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 1).reason == .recovering)
        #expect(recoveryReport(nil, corrections: 1, episodes: 2, endRealized: false).reason == .recovering)
        #expect(recoveryReport(.settling, corrections: 0).reason == .recovering)
        #expect(recoveryReport(.followToEnd, corrections: 1).reason == .recovering)
        #expect(recoveryReport(.recover(pageOffsetY: 100), corrections: 1, endRealized: false).reason == .recovering)
    }

    /// The summary names the reason with its evidence and reads next to the
    /// forced follow's report once that follow has reported — on every
    /// launch, `notAttempted` included — never on the pending report.
    @Test func recoveryReportSummaryIsAppendedOnlyAfterTheFollowReports() {
        let policy = ConversationTranscriptScrollPolicy.self
        let notAttempted = recoveryReport(nil, episodes: 0, endRealized: false)
        #expect(notAttempted.summary == "endRecovery=notAttempted corrections=0 episodes=0 endRealized=false")
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, episodes: 2).summary
            == "endRecovery=recovered corrections=1 episodes=2 endRealized=true")
        #expect(recoveryReport(RecoveryStep.none, corrections: 1, endRealized: false).summary
            == "endRecovery=unverified corrections=1 episodes=1 endRealized=false")
        #expect(recoveryReport(RecoveryStep.none).summary
            == "endRecovery=noCorrectionNeeded corrections=0 episodes=1 endRealized=true")
        #expect(recoveryReport(.giveUp, corrections: 3, endRealized: false).summary
            == "endRecovery=gaveUp corrections=3 episodes=1 endRealized=false")
        #expect(recoveryReport(.yieldToUser, corrections: 1, endRealized: false).summary
            == "endRecovery=yieldedToUser corrections=1 episodes=1 endRealized=false")
        #expect(recoveryReport(nil, cancelled: true).summary
            == "endRecovery=cancelled corrections=0 episodes=1 endRealized=true")
        #expect(recoveryReport(nil, endRealized: false).summary
            == "endRecovery=recovering corrections=0 episodes=1 endRealized=false")
        #expect(policy.forcedFollowLandingSummary(
            outcome: .landed,
            corrections: 0,
            endRecovery: notAttempted.summary
        ) == "lastForcedFollow=landed corrections=0 endRecovery=notAttempted corrections=0 episodes=0 endRealized=false")
        #expect(policy.forcedFollowLandingSummary(
            outcome: .giveUp,
            corrections: 2,
            endRecovery: recoveryReport(RecoveryStep.none, corrections: 1).summary
        ) == "lastForcedFollow=giveUp corrections=2 endRecovery=recovered corrections=1 episodes=1 endRealized=true")
        #expect(policy.forcedFollowLandingSummary(
            outcome: .landed,
            corrections: 0,
            endRecovery: nil
        ) == "lastForcedFollow=landed corrections=0")
        #expect(policy.forcedFollowLandingSummary(
            outcome: nil,
            corrections: 0,
            endRecovery: notAttempted.summary
        ) == "lastForcedFollow=pending")
    }

    @MainActor
    @Test func pageToMovesTheLiveScrollViewOrReportsItMissing() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentSize = CGSize(width: 390, height: 3_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 2_300)
        let proxy = ScrollViewMomentumProxy()
        #expect(!proxy.pageTo(offsetY: 1_600))
        proxy.scrollView = scrollView
        #expect(proxy.pageTo(offsetY: 1_600))
        #expect(scrollView.contentOffset.y == 1_600)
    }
}
// swiftlint:enable function_body_length no_magic_numbers number_separator trailing_newline