import Foundation
@testable import Intent
import Testing
import UIKit

struct ConversationTranscriptScrollPolicyTests {
    private typealias Step = ConversationTranscriptScrollPolicy.InitialScrollStep

    private func initialStep(
        alreadyPerformed: Bool = false,
        scrollViewResolved: Bool = false,
        scrollViewWaitElapsed: Bool = false
    ) -> Step {
        ConversationTranscriptScrollPolicy.initialScrollStep(
            alreadyPerformed: alreadyPerformed,
            scrollViewResolved: scrollViewResolved,
            scrollViewWaitElapsed: scrollViewWaitElapsed
        )
    }

    /// Regression: with an instant load the 0.1 s entry timer elapsed during
    /// the push transition, `scrollTo("new-messages-divider")` ran before the
    /// UIScrollView was hosted and was lost, so the viewport stayed at the
    /// bottom instead of on the divider. The timer firing first must wait for
    /// the finder's edge rather than scroll.
    @Test func entryScrollWaitsForFinderWhenTimerBeatsHosting() {
        #expect(initialStep(scrollViewResolved: false) == .waitForScrollView)
        #expect(initialStep(scrollViewResolved: true) == .perform)
    }

    /// A finder that never resolves may not leave the transcript unscrolled.
    @Test func entryScrollFallsBackAfterBoundedWait() {
        #expect(initialStep(scrollViewResolved: false, scrollViewWaitElapsed: true) == .perform)
    }

    /// The finder edge and the bounded-wait fallback can both fire; only the
    /// first performs.
    @Test func entryScrollPerformsAtMostOnce() {
        #expect(initialStep(alreadyPerformed: true, scrollViewResolved: true) == .skip)
        #expect(initialStep(alreadyPerformed: true, scrollViewWaitElapsed: true) == .skip)
        #expect(initialStep(alreadyPerformed: true) == .skip)
    }

    /// The hosting wait must outlast the entry timer it replaces, and the
    /// divider probe must run before `hasInitiallyScrolled` flips so no
    /// automatic follow can be queued ahead of its decision.
    @Test func entryScrollDelaysAreOrdered() {
        #expect(Constants.Conversation.Transcript.initialScrollHostingTimeout
            > Constants.Conversation.Transcript.initialScrollDelay)
        #expect(Constants.Conversation.Transcript.dividerProbeDelay
            < Constants.Conversation.Transcript.initialScrollSettleDelay)
    }

    @Test func tracksAwayStateAcrossBottomThreshold() {
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: -20))
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: 50))
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: 51))
    }

    @Test func distanceToBottomIsZeroAtRestAtBottom() {
        // contentOffset.y at the bottom = contentSize + bottomInset - container.
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 300,
            containerHeight: 700
        ) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 334,
            containerHeight: 700,
            bottomInset: 34
        ) == 0)
    }

    /// Regression: SwiftUI's `ScrollGeometry.containerSize` excludes the
    /// safe-area insets while `contentOffset` includes them, so measuring
    /// with it read the navigation-bar inset at rest at the bottom and
    /// "scrolled away" never cleared. `visibleRect.height` spans the full
    /// bounds (container + insets) and is the container the formula expects.
    @Test func distanceToBottomIsZeroAtRestUnderTopInsetWhenMeasuredWithVisibleRect() {
        // Simulator reading: content 1968, offset 1188, containerSize 664,
        // contentInsets.top 116, visibleRect.height 780.
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 780
        ) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1968,
            contentOffsetY: 1188,
            containerHeight: 664
        ) == 116)
    }

    @Test func distanceToBottomGrowsAsViewportScrollsUp() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 100,
            containerHeight: 700
        ) == 200)
    }

    func transition(
        current: Bool,
        distanceToBottom: CGFloat,
        isInteracting: Bool,
        isEndRealized: Bool = true
    ) -> Bool {
        ConversationTranscriptScrollPolicy.scrolledAwayTransition(
            current: current,
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom,
                atBottomThreshold: 50
            ),
            isInteracting: isInteracting,
            isEndRealized: isEndRealized
        )
    }

    /// The rule behind #272, #280 and #281: content growing under a pinned
    /// viewport (a row re-measuring, a footer row, the keyboard, streaming,
    /// an append) reads "away" without a gesture and must not break the pin.
    @Test func contentGrowthWhilePinnedWithoutGestureKeepsThePin() {
        #expect(!transition(current: false, distanceToBottom: 51, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 379, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 0, isInteracting: false))
    }

    @Test func draggingUpBeyondThresholdScrollsAway() {
        #expect(transition(current: false, distanceToBottom: 51, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: 50, isInteracting: true))
    }

    /// `isInteracting` covers the deceleration after a fling: one that comes
    /// to rest past the threshold is away, one that returns within it is not.
    @Test func decelerationAfterFlingDecidesByWhereItRests() {
        #expect(transition(current: false, distanceToBottom: 200, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: 20, isInteracting: true))
    }

    /// Back within the threshold re-pins whether the user dragged back down
    /// or Go to End landed the follow (no gesture).
    @Test func returningWithinThresholdRePinsWithOrWithoutGesture() {
        #expect(!transition(current: true, distanceToBottom: 50, isInteracting: true))
        #expect(!transition(current: true, distanceToBottom: 0, isInteracting: false))
        #expect(!transition(current: true, distanceToBottom: -30, isInteracting: false))
    }

    /// A scrolled-away reader stays scrolled away while content grows under
    /// the viewport; only geometry back at the bottom clears it.
    @Test func scrolledAwayStaysAwayWhileContentGrows() {
        #expect(transition(current: true, distanceToBottom: 400, isInteracting: false))
        #expect(transition(current: true, distanceToBottom: 400, isInteracting: true))
    }

    /// A bounce past the end while pinned reads a negative distance, at the
    /// bottom: the gesture does not scroll away.
    @Test func bouncePastEndWhilePinnedStaysPinned() {
        #expect(!transition(current: false, distanceToBottom: -60, isInteracting: true))
        #expect(!transition(current: false, distanceToBottom: -60, isInteracting: false))
    }

    func rePinAfterGrowth(
        geometryAway: Bool = true,
        isInteracting: Bool = false,
        isFollowing: Bool = false,
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldRePinAfterContentGrowth(
            geometryAway: geometryAway,
            isInteracting: isInteracting,
            isFollowing: isFollowing,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    /// Growth under a pinned, settled viewport is followed to the new end.
    @Test func contentGrowthUnderPinnedViewportRePins() {
        #expect(rePinAfterGrowth())
        #expect(!rePinAfterGrowth(geometryAway: false))
    }

    /// Not under the finger (a gesture, not growth), not while a follow is
    /// already landing there, not before the entry scroll has decided (the
    /// unread divider), and not for a reader who scrolled away.
    @Test func contentGrowthRePinYieldsToGesturesFollowsAndTheEntryDecision() {
        #expect(!rePinAfterGrowth(isInteracting: true))
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(!rePinAfterGrowth(hasInitiallyScrolled: false))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
    }

    @Test func distanceToBottomIsNegativeForShortContentAndOverscroll() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 400,
            contentOffsetY: 0,
            containerHeight: 700
        ) == -300)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1000,
            contentOffsetY: 360,
            containerHeight: 700
        ) == -60)
    }

    private typealias RePinDecision = ConversationTranscriptScrollPolicy.RePinDecision

    /// Geometry of a 1 000 pt transcript in a 700 pt viewport; `offsetY` is
    /// the resting offset (300 is the bottom) and the distance follows.
    private func rePinDecision(
        offsetY: CGFloat,
        isInteracting: Bool = false,
        contentHeight: CGFloat = 1000,
        containerHeight: CGFloat = 700,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> RePinDecision {
        ConversationTranscriptScrollPolicy.rePinDecision(
            contentOffsetY: offsetY,
            distanceToBottom: ConversationTranscriptScrollPolicy.distanceToBottom(
                contentHeight: contentHeight,
                contentOffsetY: offsetY,
                containerHeight: containerHeight,
                bottomInset: bottomInset
            ),
            isInteracting: isInteracting,
            contentHeight: contentHeight,
            containerHeight: containerHeight,
            verticalInsets: topInset + bottomInset,
            atBottomThreshold: 50
        )
    }

    /// Regression (#271): on return to a conversation the viewport could rest
    /// past the end of the content — a blank band under the last message —
    /// while `isScrolledAway` read "at bottom" and hid Go to End.
    @Test func restingPastEndIsClampedToBottom() {
        #expect(rePinDecision(offsetY: 351) == .rePin(offsetY: 300))
        #expect(rePinDecision(offsetY: 600) == .rePin(offsetY: 300))
        #expect(rePinDecision(offsetY: 350) == .none)
        #expect(rePinDecision(offsetY: 300) == .none)
        #expect(rePinDecision(offsetY: 100) == .none)
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: -300))
    }

    /// A bounce past the bottom reads the same negative distance; the
    /// viewport is dragging or decelerating then and must settle on its own.
    @Test func bouncingPastEndIsDeferred() {
        #expect(rePinDecision(offsetY: 380, isInteracting: true) == .deferred)
        #expect(rePinDecision(offsetY: 600, isInteracting: true) == .deferred)
        #expect(rePinDecision(offsetY: 380, isInteracting: false) == .rePin(offsetY: 300))
    }

    /// Content shorter than the container rests at a negative distance by
    /// construction; there is no end to be past.
    @Test func shortContentIsNotPastEnd() {
        #expect(rePinDecision(offsetY: 0, contentHeight: 400, containerHeight: 700) == .none)
        #expect(rePinDecision(offsetY: 100, contentHeight: 700, containerHeight: 700) == .none)
        // Insets shrink the room the content has: 650 pt of content fits a
        // 780 pt container outright, but not once 150 pt of insets are taken.
        #expect(rePinDecision(offsetY: 0, contentHeight: 650, containerHeight: 780) == .none)
        #expect(rePinDecision(
            offsetY: 0,
            contentHeight: 650,
            containerHeight: 780,
            topInset: 150
        ) == .rePin(offsetY: -130))
    }

    /// A bottom inset (keyboard, composer) is part of the bottom the
    /// viewport is clamped to.
    @Test func pastEndClampAccountsForBottomInset() {
        #expect(rePinDecision(offsetY: 400, bottomInset: 20) == .rePin(offsetY: 320))
        #expect(rePinDecision(offsetY: 320, bottomInset: 20) == .none)
    }

    /// The two confirming reads must agree on the insets the clamp is
    /// computed from: a keyboard or safe-area change between them with the
    /// offset, content and bounds unchanged is not a settled layout. Drives
    /// the live re-pin against a UIScrollView resting past the end.
    @MainActor
    @Test func restingGeometryConfirmationIncludesAdjustedInsets() {
        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.contentInset = UIEdgeInsets(top: 59, left: 0, bottom: 34, right: 0)
        scrollView.contentSize = CGSize(width: 390, height: 1000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        let proxy = ScrollViewMomentumProxy()
        proxy.scrollView = scrollView

        // First read past the end: deferred, carrying the insets it read.
        guard case let .deferred(first?) = proxy.rePinIfRestingPastEnd(confirming: nil) else {
            Issue.record("first past-end read was not deferred with a geometry")
            return
        }
        #expect(first.topInset == 59)
        #expect(first.bottomInset == 34)
        #expect(first.contentOffsetY == 500)

        // The bottom inset grows between the reads (still past the end) with
        // offset, content and bounds unchanged: not confirmed, the new read
        // replaces the first. UIKit clamps the offset into range when the
        // inset changes on a resting scroll view; restore it, as the lazy
        // stack's re-layout leaves it where it was.
        scrollView.contentInset.bottom = 100
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        guard case let .deferred(second?) = proxy.rePinIfRestingPastEnd(confirming: first) else {
            Issue.record("a changed inset was accepted as the confirming read")
            return
        }
        #expect(second.bottomInset == 100)
        #expect(second != first)
        #expect(scrollView.contentOffset.y == 500)

        // Two identical reads: clamped to the bottom the insets define
        // (content 1_000 + bottom inset 100 − viewport 700).
        let clampedOffsetY: CGFloat = 400
        #expect(proxy.rePinIfRestingPastEnd(confirming: second) == .rePinned)
        #expect(scrollView.contentOffset.y == clampedOffsetY)
    }

    @Test func pastEndGeometryIgnoresInteractionState() {
        #expect(ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -80,
            contentHeight: 1000,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -80,
            contentHeight: 400,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -20,
            contentHeight: 1000,
            containerHeight: 700,
            atBottomThreshold: 50
        ))
    }

    typealias ContainerRePin = ConversationTranscriptScrollPolicy.ContainerRePinDecision
}
