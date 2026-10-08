import Foundation
@testable import Intent
import Testing
import UIKit

// Geometry regression values intentionally mirror the observed scroll offsets.
// swiftlint:disable no_magic_numbers number_separator

extension ConversationTranscriptScrollPolicyTests {
    typealias RecoveryStep = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryStep
    typealias RecoveryTerminal = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryTerminal

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
        previousPageOffsetY: CGFloat? = nil,
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
            previousPageOffsetY: previousPageOffsetY,
            timedOut: timedOut,
            atBottomThreshold: 50,
            landingTolerance: 1
        )
    }

    /// A following viewport at the bottom with no realized end row is paged
    /// up one viewport and followed back to the end (#338).
    @Test func blankViewportAtTheBottomIsPagedUpAndFollowedBack() {
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000)) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(recovery(geometry(offsetY: 2_299.5, contentHeight: 3_000)) == .continue(.recover(pageOffsetY: 1_599.5)))
        #expect(recovery(geometry(offsetY: 2_340, contentHeight: 3_000)) == .continue(.recover(pageOffsetY: 1_600)))
        #expect(recovery(geometry(offsetY: 300)) == .continue(.recover(pageOffsetY: 0)))
        #expect(recovery(geometry(offsetY: 50, contentHeight: 750, topInset: 59))
            == .continue(.recover(pageOffsetY: -59)))
    }

    /// A first short rest inside the bottom band follows once; an unchanged
    /// geometry after that escalates to paging up.
    @Test func shortRestInsideTheBandIsFollowedOnceThenPagedUp() {
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000)) == .continue(.followToEnd))
        #expect(recovery(geometry(offsetY: 2_251, contentHeight: 3_000)) == .continue(.followToEnd))
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsSpent: 1)
            == .continue(.recover(pageOffsetY: 1_570)))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000), correctionsSpent: 1)
            == .continue(.recover(pageOffsetY: 1_600)))
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsLeft: 0) == .finish(.giveUp))
    }

    @Test func realizedEndRowNeedsNoRecovery() {
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 270), isEndRealized: true) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 600), isEndRealized: true) == .finish(.notNeeded))
        #expect(recovery(nil, isEndRealized: true) == .finish(.notNeeded))
    }

    @Test func recoveryWaitsForPastEndClampingAndIgnoresShortContent() {
        #expect(recovery(geometry(offsetY: 351)) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 600)) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 249)) == .continue(.followToEnd))
        #expect(recovery(geometry(offsetY: 0)) == .continue(.followToEnd))
        #expect(recovery(geometry(offsetY: 0), timedOut: true) == .finish(.giveUp))
        #expect(recovery(geometry(offsetY: 0, contentHeight: 400)) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 0, contentHeight: 650, containerHeight: 780)) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 0, contentHeight: 650, containerHeight: 780, topInset: 150))
            == .continue(.followToEnd))
    }

    @Test func unsuccessfulFollowKeepsSearchingAboveThePreviousPage() {
        let initial = geometry(offsetY: 9_300, contentHeight: 10_000)
        #expect(recovery(initial, correctionsLeft: 3) == .continue(.recover(pageOffsetY: 8_600)))

        // The end jump may move nowhere, or return to the same bad estimate.
        for offset in [CGFloat(8_600), 9_300, 9_600] {
            #expect(recovery(
                geometry(offsetY: offset, contentHeight: offset + 700),
                correctionsSpent: 1,
                previousPageOffsetY: 8_600
            ) == .continue(.recover(pageOffsetY: 7_900)))
        }
        #expect(recovery(
            geometry(offsetY: 8_600, contentHeight: 10_000),
            correctionsSpent: 1,
            previousPageOffsetY: 8_600
        ) == .continue(.recover(pageOffsetY: 7_900)))
        #expect(recovery(
            initial, correctionsLeft: 1, correctionsSpent: 2, previousPageOffsetY: 7_900
        ) == .continue(.recover(pageOffsetY: 0)))
        #expect(recovery(
            geometry(offsetY: 9_300, contentHeight: 10_000, topInset: 59),
            correctionsLeft: 1,
            correctionsSpent: 2,
            previousPageOffsetY: 7_900
        ) == .continue(.recover(pageOffsetY: -59)))
    }

    @Test func shortFailedLandingCanRecoverWithoutAUserGesture() {
        let short = geometry(offsetY: 7_200, contentHeight: 10_000)
        #expect(recovery(short, correctionsLeft: 3) == .continue(.followToEnd))
        #expect(recovery(short, correctionsSpent: 1) == .continue(.recover(pageOffsetY: 6_500)))
        #expect(recovery(short, correctionsSpent: 1, userIsScrolledAway: true) == .finish(.notNeeded))
        #expect(recovery(short, correctionsSpent: 1, isInteracting: true) == .continue(.settling))
        #expect(recovery(short, correctionsLeft: 0, correctionsSpent: 3) == .finish(.giveUp))
    }

    @Test func recoveryContinuesWhenRemeasurementMovesTheEndAboveItsOffset() {
        let shrunk = geometry(offsetY: 8_600, contentHeight: 8_000)
        #expect(recovery(shrunk) == .continue(.settling))
        #expect(recovery(
            shrunk,
            correctionsSpent: 1,
            previousPageOffsetY: 8_600
        ) == .continue(.recover(pageOffsetY: 6_600)))
        #expect(recovery(shrunk, correctionsSpent: 1, isInteracting: true) == .continue(.settling))
        #expect(recovery(shrunk, correctionsLeft: 0, correctionsSpent: 3) == .finish(.giveUp))
    }

    @Test func recoveryWaitsForRestAndForGesturesAndFollows() {
        #expect(recovery(nil) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), previous: .some(nil)) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 250)) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 300, bottomInset: 20))
            == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), isInteracting: true) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), isFollowing: true) == .continue(.settling))
    }

    @Test func recoveryIsBoundedAndIgnoresNonFollowingViewports() {
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 1) == .continue(.recover(pageOffsetY: 0)))
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 0) == .finish(.giveUp))
        #expect(recovery(geometry(offsetY: 300), timedOut: true) == .finish(.giveUp))
        #expect(recovery(nil, timedOut: true) == .finish(.giveUp))
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, timedOut: true) == .finish(.giveUp))
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, timedOut: true) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 300), hasInitiallyScrolled: false) == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true, correctionsLeft: 0) == .finish(.notNeeded))
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
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, correctionsSpent: 1) == .continue(.settling))
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, correctionsSpent: 1)
            == .finish(.notNeeded))
        #expect(recovery(geometry(offsetY: 300), isFollowing: true, correctionsSpent: 1) == .continue(.settling))
    }

    /// The report of a transcript with one episode armed, resolved on
    /// `outcome` (nil: still running) with the end row realized by default.
    private func recoveryReport(
        _ outcome: RecoveryTerminal?,
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
    /// finish; a `.notNeeded` that spent nothing is `noCorrectionNeeded`, one over
    /// a still unrealized end row is `unverified` (neither recovered nor a
    /// give-up: the budget was not spent and Go to End is not shown).
    @Test func recoveryReportLabelsRecoveredOnlyWithACorrectionAndTheEndRealized() {
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: true).reason == .recovered)
        #expect(recoveryReport(.notNeeded, corrections: 3, endRealized: true).reason == .recovered)
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: false).reason == .unverified)
        #expect(recoveryReport(.notNeeded, corrections: 0, endRealized: true).reason == .noCorrectionNeeded)
        #expect(recoveryReport(.notNeeded, corrections: 0, endRealized: false).reason == .noCorrectionNeeded)
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: false).reason != .recovered)
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: false).reason != .gaveUp)
        let report = recoveryReport(.notNeeded, corrections: 2, episodes: 3, endRealized: true)
        #expect(report == ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryReport(
            reason: .recovered,
            corrections: 2,
            episodes: 3,
            endRealized: true
        ))
    }

    /// An abandoned episode is never `recovered`: a give-up is `gaveUp`, a
    /// yield is `yieldedToUser`, and a cancelled task is `cancelled`
    /// whatever terminal it reached, a `.notNeeded` included, or none.
    @Test func recoveryReportNeverLabelsAnAbandonedEpisodeRecovered() {
        for corrections in [0, 1, 3] {
            for endRealized in [false, true] {
                #expect(recoveryReport(.giveUp, corrections: corrections, endRealized: endRealized).reason == .gaveUp)
                #expect(recoveryReport(.yieldToUser, corrections: corrections, endRealized: endRealized).reason == .yieldedToUser)
                #expect(recoveryReport(nil, corrections: corrections, endRealized: endRealized, cancelled: true).reason == .cancelled)
                #expect(recoveryReport(
                    .yieldToUser,
                    corrections: corrections,
                    endRealized: endRealized,
                    cancelled: true
                ).reason == .cancelled)
            }
        }
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: true, cancelled: true).reason == .cancelled)
        #expect(recoveryReport(.giveUp, corrections: 1, endRealized: true, cancelled: true).reason == .cancelled)
    }

    /// No episode armed is `notAttempted` whatever else is handed; an armed
    /// episode without a terminal (the loop is settling, following or
    /// paging — only a terminal is ever handed) is `recovering`.
    @Test func recoveryReportDistinguishesNotAttemptedFromInFlight() {
        #expect(recoveryReport(nil, episodes: 0, endRealized: false).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 0, endRealized: true).reason == .notAttempted)
        #expect(recoveryReport(.notNeeded, corrections: 1, episodes: 0).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 0, cancelled: true).reason == .notAttempted)
        #expect(recoveryReport(nil, episodes: 1).reason == .recovering)
        #expect(recoveryReport(nil, corrections: 1, episodes: 2, endRealized: false).reason == .recovering)
        #expect(recoveryReport(nil, corrections: 1, endRealized: true).reason == .recovering)
    }

    /// The summary names the reason with its evidence and reads next to the
    /// forced follow's report once that follow has reported — on every
    /// launch, `notAttempted` included — never on the pending report.
    @Test func recoveryReportSummaryIsAppendedOnlyAfterTheFollowReports() {
        let policy = ConversationTranscriptScrollPolicy.self
        let notAttempted = recoveryReport(nil, episodes: 0, endRealized: false)
        #expect(notAttempted.summary == "endRecovery=notAttempted corrections=0 episodes=0 endRealized=false")
        #expect(recoveryReport(.notNeeded, corrections: 1, episodes: 2).summary
            == "endRecovery=recovered corrections=1 episodes=2 endRealized=true")
        #expect(recoveryReport(.notNeeded, corrections: 1, endRealized: false).summary
            == "endRecovery=unverified corrections=1 episodes=1 endRealized=false")
        #expect(recoveryReport(.notNeeded).summary
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
            endRecovery: recoveryReport(.notNeeded, corrections: 1).summary
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
// swiftlint:enable no_magic_numbers number_separator
