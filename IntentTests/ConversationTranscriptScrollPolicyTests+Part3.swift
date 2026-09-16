import Foundation
@testable import Intent
import Testing
import UIKit

private let kTestAtBottomThreshold: CGFloat = 50

extension ConversationTranscriptScrollPolicyTests {
    func geometry(
        offsetY: CGFloat,
        contentHeight: CGFloat = 1000,
        containerHeight: CGFloat = 700,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> ViewportGeometry {
        ViewportGeometry(
            contentOffsetY: offsetY,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            topInset: topInset,
            bottomInset: bottomInset
        )
    }

    /// A landing read that repeats the same geometry (at rest) by default.
    func landing(
        _ geometry: ViewportGeometry?,
        previous: ViewportGeometry?? = nil,
        isInteracting: Bool = false,
        userIsScrolledAway: Bool = false,
        correctionsLeft: Int = 2,
        timedOut: Bool = false
    ) -> LandingStep {
        ConversationTranscriptScrollPolicy.followLandingStep(
            geometry: geometry,
            previous: previous ?? geometry,
            isInteracting: isInteracting,
            userIsScrolledAway: userIsScrolledAway,
            correctionsLeft: correctionsLeft,
            timedOut: timedOut,
            atBottomThreshold: kTestAtBottomThreshold,
            landingTolerance: 1
        )
    }

    @Test func viewportGeometryDistanceHonoursBottomInset() {
        #expect(geometry(offsetY: 300).distanceToBottom == 0)
        #expect(geometry(offsetY: 334, bottomInset: 34).distanceToBottom == 0)
        #expect(geometry(offsetY: 100).distanceToBottom == 200)
        #expect(geometry(offsetY: 300, topInset: 10, bottomInset: 20).verticalInsets == 30)
    }

    /// The landing is verified from two identical reads: no scroll view, no
    /// previous read, or geometry still moving all keep polling.
    @Test func followLandingSettlesUntilTwoReadsAgree() {
        #expect(landing(nil) == .settling)
        #expect(landing(geometry(offsetY: 300), previous: .some(nil)) == .settling)
        #expect(landing(geometry(offsetY: 300), previous: geometry(offsetY: 250)) == .settling)
        // Insets changing (keyboard) count as movement too.
        #expect(landing(geometry(offsetY: 300), previous: geometry(offsetY: 300, bottomInset: 20)) == .settling)
    }

    @Test func followLandsAtRestWithinTheLandingTolerance() {
        #expect(landing(geometry(offsetY: 300)) == .landed)
        #expect(landing(geometry(offsetY: 299.5)) == .landed)
        #expect(landing(geometry(offsetY: 299)) == .landed)
        #expect(landing(geometry(offsetY: 298)) != .landed)
        // Content shorter than the container rests at a negative distance.
        #expect(landing(geometry(offsetY: 0, contentHeight: 400)) == .landed)
        // A bounce short of the past-end threshold is at the bottom.
        #expect(landing(geometry(offsetY: 340)) == .landed)
    }

    /// Regression (#281): Go to End's scroll came to rest 379 points above
    /// the bottom because rows realized during the animation grew the
    /// content, and the timer-ended follow copied that into the flag.
    @Test func followLandingShortIsScrolledAgain() {
        #expect(landing(geometry(offsetY: 0)) == .scrollAgain)
        #expect(landing(geometry(offsetY: 249)) == .scrollAgain)
    }

    /// Regression (#304, #305): the last rows realized by the entry scroll,
    /// or the sent row and thinking indicator after a send, grew the content
    /// by less than the at-bottom band. The follow rested inside the band —
    /// "at bottom", Go to End hidden — with the rows under the last message
    /// below the viewport; a rest short of the bottom by more than layout
    /// rounding is scrolled again even inside the band.
    @Test func followLandingShortInsideTheAtBottomBandIsScrolledAgain() {
        #expect(landing(geometry(offsetY: 298)) == .scrollAgain)
        #expect(landing(geometry(offsetY: 270)) == .scrollAgain)
        #expect(landing(geometry(offsetY: 250)) == .scrollAgain)
        #expect(landing(geometry(offsetY: 250), correctionsLeft: 0) == .giveUp)
        #expect(Constants.Conversation.Transcript.followLandingTolerance
            < Constants.Conversation.Transcript.atBottomThreshold)
    }

    /// Regression (#271): rows re-measured shorter after the entry scroll
    /// left the offset past the end, over a blank band.
    @Test func followLandingPastEndIsClamped() {
        #expect(landing(geometry(offsetY: 351)) == .clampPastEnd)
        #expect(landing(geometry(offsetY: 600)) == .clampPastEnd)
    }

    /// Corrections are bounded and their exhaustion leaves the pin alone:
    /// no forced follow ever shows Go to End without a gesture.
    @Test func followLandingCorrectionsAreBoundedAndThenGiveUp() {
        #expect(landing(geometry(offsetY: 0), correctionsLeft: 1) == .scrollAgain)
        #expect(landing(geometry(offsetY: 0), correctionsLeft: 0) == .giveUp)
        #expect(landing(geometry(offsetY: 600), correctionsLeft: 0) == .giveUp)
        #expect(landing(geometry(offsetY: 300), correctionsLeft: 0) == .landed)
        #expect(Constants.Conversation.Transcript.followLandingRetries > 0)
        // The timeout leaves room for the first scroll and every correction
        // to animate and then settle over two reads (#305).
        let rounds = Double(Constants.Conversation.Transcript.followLandingRetries + 1)
        let roundMilliseconds = Constants.Conversation.Transcript.scrollAnimationDuration * 1000
            + Double(2 * Constants.Conversation.Transcript.followLandingPollMilliseconds)
        #expect(rounds * roundMilliseconds < Double(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds))
    }

    /// The accessibility value the UI tests read under demo data names the
    /// outcome and the corrections spent, and reads pending in flight.
    @Test func forcedFollowLandingSummaryNamesOutcomeAndCorrections() {
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(outcome: nil, corrections: 0)
            == "lastForcedFollow=pending")
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(outcome: .landed, corrections: 1)
            == "lastForcedFollow=landed corrections=1")
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(outcome: .giveUp, corrections: 3)
            == "lastForcedFollow=giveUp corrections=3")
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(outcome: .yieldToUser, corrections: 0)
            == "lastForcedFollow=yieldToUser corrections=0")
    }

    @Test func followLandingYieldsToTheUserAndToTheTimeout() {
        #expect(landing(geometry(offsetY: 0), isInteracting: true) == .yieldToUser)
        #expect(landing(geometry(offsetY: 300), isInteracting: true) == .yieldToUser)
        #expect(landing(nil, isInteracting: true) == .yieldToUser)
        #expect(landing(geometry(offsetY: 0), timedOut: true) == .giveUp)
        #expect(landing(nil, timedOut: true) == .giveUp)
        #expect(landing(geometry(offsetY: 300), previous: geometry(offsetY: 250), timedOut: true) == .giveUp)
        #expect(landing(geometry(offsetY: 0), isInteracting: true, timedOut: true) == .yieldToUser)
        #expect(Constants.Conversation.Transcript.followLandingPollMilliseconds
            < Constants.Conversation.Transcript.followLandingTimeoutMilliseconds)
    }

    /// A gesture that started and ended between two landing polls left only
    /// the raised flag behind; the landing yields to it rather than scrolling
    /// the user back, even from a viewport at rest short of the bottom.
    @Test func followLandingYieldsToAGestureThatAlreadyEndedAway() {
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: true) == .yieldToUser)
        #expect(landing(geometry(offsetY: 300), userIsScrolledAway: true) == .yieldToUser)
        #expect(landing(nil, userIsScrolledAway: true) == .yieldToUser)
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: true, timedOut: true) == .yieldToUser)
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: false) == .scrollAgain)
    }

    /// An unknown distance never releases a scrolled-away state: every
    /// automatic path stays suppressed until the geometry proves otherwise.
    @Test func unknownDistanceDoesNotFlipScrolledAwayBackToPinned() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
        #expect(!streamingDelta(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true,
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
    }

    @Test func streamingFollowConstantsAreDocumentedDefaults() {
        #expect(Constants.Conversation.Transcript.streamingFollowMinimumInterval > 0)
        #expect(Constants.Conversation.Transcript.streamingFollowDriftTolerance >= 0)
        #expect(Constants.Conversation.Transcript.streamingFollowDriftTolerance
            < Constants.Conversation.Transcript.atBottomThreshold)
    }
}
