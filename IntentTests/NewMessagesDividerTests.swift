import Foundation
import Testing
import UIKit
@testable import Intent

/// Ports of the desktop cases in new-messages-divider.test.ts.
struct NewMessagesDividerAnchorTests {
    private let ids = ["m1", "m2", "m3", "m4"]

    @Test func anchorsAtMarkerOlderThanNewest() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: "m2") == "m2")
    }

    @Test func anchorsAtSecondToLastMessage() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: "m3") == "m3")
    }

    @Test func anchorsAtOldestMessage() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: "m1") == "m1")
    }

    @Test func nilWhenNoMarker() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: nil) == nil)
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: "") == nil)
    }

    @Test func nilWhenMarkerIsNewest() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: ids, lastSeenMessageId: "m4") == nil)
    }

    @Test func nilForDanglingMarker() {
        #expect(NewMessagesDivider.resolveAnchor(
            messageIds: ids, lastSeenMessageId: "truncated-away") == nil)
    }

    @Test func nilForEmptyTranscript() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: [], lastSeenMessageId: "m1") == nil)
    }
}

struct NewMessagesDividerLatchedTests {
    private let ids = ["m1", "m2", "m3", "m4"]

    @Test func rendersAtLatchedAnchorWhilePresent() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids, latchedAnchorId: "m2") == "m2")
    }

    @Test func keepsLatchedAnchorEvenWhenNewest() {
        // The entry-time resolver never latches the newest message, but a
        // latched anchor that BECAME newest (trailing rows truncated) still
        // renders as-is.
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids, latchedAnchorId: "m4") == "m4")
    }

    @Test func staysPutAsTranscriptGrows() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids, latchedAnchorId: "m2") == "m2")
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids + ["m5", "m6"], latchedAnchorId: "m2") == "m2")
    }

    @Test func nilForNilLatch() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: ids, latchedAnchorId: nil) == nil)
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: ids, latchedAnchorId: "") == nil)
    }

    @Test func hidesNotRecomputesWhenAnchorLeftTranscript() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ["m1", "m3", "m4"], latchedAnchorId: "m2") == nil)
    }

    @Test func nilForEmptyTranscript() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: [], latchedAnchorId: "m2") == nil)
    }
}

/// Entry-scroll follow decision in the bottom-anchored list (distance to
/// bottom ≈ 0 is the visual bottom; threshold mirrors the list's at-bottom
/// detection).
struct NewMessagesDividerEntryScrollTests {
    @Test func followStaysEnabledWhenClampedAtBottom() {
        // Unseen tail fits on screen: the divider scroll clamps at the
        // bottom, so follow-to-bottom keeps today's behavior.
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: 0))
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: 50))
    }

    @Test func followStaysEnabledWhileBouncedPastBottom() {
        // A scroll view can rest or bounce past the end of its content
        // (negative distance) — still the visual bottom.
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: -59))
    }

    @Test func followDisabledWhenLandedOnDividerAwayFromBottom() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: 51))
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: 2_000))
    }

    /// Regression: an unknown distance after landing on the divider must not
    /// be read as bottom-pinned (which hid Go to End and let a later follow
    /// pull the user off the divider).
    @Test func followDisabledWhenDistanceIsUnknownAfterDividerLanding() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: nil))
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: nil, atBottomThreshold: 10_000))
    }

    @Test func honorsCustomThreshold() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: 30, atBottomThreshold: 10))
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: 30, atBottomThreshold: 100))
    }
}

/// Regression coverage for intent-hq/ios#270: the finder must resolve the
/// transcript UIScrollView once attached to a window, not from an eager
/// one-shot walk that runs before the hierarchy exists.
@MainActor
struct ScrollViewFinderTests {
    @Test func firstScrollViewAncestorFindsNearestScrollView() {
        let outer = UIScrollView()
        let inner = UIScrollView()
        let host = UIView()
        let leaf = UIView()
        outer.addSubview(inner)
        inner.addSubview(host)
        host.addSubview(leaf)
        #expect(ScrollViewFinder.firstScrollViewAncestor(of: leaf) === inner)
        #expect(ScrollViewFinder.firstScrollViewAncestor(of: inner) === outer)
    }

    @Test func firstScrollViewAncestorIsNilWithoutScrollViewAbove() {
        let root = UIView()
        let leaf = UIView()
        root.addSubview(leaf)
        #expect(ScrollViewFinder.firstScrollViewAncestor(of: leaf) == nil)
        #expect(ScrollViewFinder.firstScrollViewAncestor(of: UIScrollView()) == nil)
    }

    @Test func finderResolvesProxyOnWindowAttachAndInstallsTapOnce() {
        let proxy = ScrollViewMomentumProxy()
        let finder = ScrollViewFinder.FinderView()
        finder.proxy = proxy
        let scrollView = UIScrollView()
        let host = UIView()
        scrollView.addSubview(host)
        host.addSubview(finder)
        // Detached hierarchy: nothing resolves yet (mirrors makeUIView time).
        #expect(proxy.scrollView == nil)
        #expect(!proxy.hasResolvedScrollView)
        #expect(!ScrollViewFinder.hasKeyboardDismissTap(scrollView))

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(scrollView)
        #expect(proxy.scrollView === scrollView)
        #expect(proxy.hasResolvedScrollView)
        #expect(ScrollViewFinder.hasKeyboardDismissTap(scrollView))
        let tapCount = { scrollView.gestureRecognizers?.count ?? 0 }
        let installed = tapCount()

        // Re-attaching re-runs the walk without duplicating the gesture.
        scrollView.removeFromSuperview()
        window.addSubview(scrollView)
        #expect(proxy.scrollView === scrollView)
        #expect(tapCount() == installed)
    }

    @Test func finderWithoutProxyAttachesWithoutInstallingAnything() {
        let finder = ScrollViewFinder.FinderView()
        let scrollView = UIScrollView()
        scrollView.addSubview(finder)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(scrollView)
        #expect(!ScrollViewFinder.hasKeyboardDismissTap(scrollView))
    }

    /// The `updateUIView` path: a proxy handed to an already-hosted finder
    /// resolves at once rather than on the next window move.
    @Test func finderResolvesProxyAssignedAfterWindowAttach() {
        let finder = ScrollViewFinder.FinderView()
        let scrollView = UIScrollView()
        scrollView.addSubview(finder)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.addSubview(scrollView)

        let proxy = ScrollViewMomentumProxy()
        finder.proxy = proxy
        #expect(proxy.scrollView === scrollView)
        #expect(proxy.hasResolvedScrollView)
        #expect(ScrollViewFinder.hasKeyboardDismissTap(scrollView))
        let installed = scrollView.gestureRecognizers?.count ?? 0

        // Re-assigning the same proxy is a no-op.
        finder.proxy = proxy
        #expect(scrollView.gestureRecognizers?.count == installed)
    }
}

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
            scrollViewWaitElapsed: scrollViewWaitElapsed)
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
            contentHeight: 1_000, contentOffsetY: 300, containerHeight: 700) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_000, contentOffsetY: 334, containerHeight: 700, bottomInset: 34) == 0)
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
            contentHeight: 1_968, contentOffsetY: 1_188, containerHeight: 780) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_968, contentOffsetY: 1_188, containerHeight: 664) == 116)
    }

    @Test func distanceToBottomGrowsAsViewportScrollsUp() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_000, contentOffsetY: 100, containerHeight: 700) == 200)
    }

    private func transition(current: Bool, distanceToBottom: CGFloat, isInteracting: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.scrolledAwayTransition(
            current: current,
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom, atBottomThreshold: 50),
            isInteracting: isInteracting)
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

    private func rePinAfterGrowth(
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
            userIsScrolledAway: userIsScrolledAway)
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
            contentHeight: 400, contentOffsetY: 0, containerHeight: 700) == -300)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_000, contentOffsetY: 360, containerHeight: 700) == -60)
    }

    private typealias RePinDecision = ConversationTranscriptScrollPolicy.RePinDecision

    /// Geometry of a 1 000 pt transcript in a 700 pt viewport; `offsetY` is
    /// the resting offset (300 is the bottom) and the distance follows.
    private func rePinDecision(
        offsetY: CGFloat,
        isInteracting: Bool = false,
        contentHeight: CGFloat = 1_000,
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
            offsetY: 0, contentHeight: 650, containerHeight: 780, topInset: 150
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
        scrollView.contentSize = CGSize(width: 390, height: 1_000)
        scrollView.contentOffset = CGPoint(x: 0, y: 500)
        let proxy = ScrollViewMomentumProxy()
        proxy.scrollView = scrollView

        // First read past the end: deferred, carrying the insets it read.
        guard case .deferred(let first?) = proxy.rePinIfRestingPastEnd(confirming: nil) else {
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
        guard case .deferred(let second?) = proxy.rePinIfRestingPastEnd(confirming: first) else {
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
            distanceToBottom: -80, contentHeight: 1_000, containerHeight: 700, atBottomThreshold: 50))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -80, contentHeight: 400, containerHeight: 700, atBottomThreshold: 50))
        #expect(!ConversationTranscriptScrollPolicy.isPastEnd(
            distanceToBottom: -20, contentHeight: 1_000, containerHeight: 700, atBottomThreshold: 50))
    }

    private typealias ContainerRePin = ConversationTranscriptScrollPolicy.ContainerRePinDecision

    private func rePinOnContainerChange(
        from oldHeight: CGFloat, to newHeight: CGFloat,
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true, userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.containerHeightChangeDecision(
            oldContainerHeight: oldHeight,
            newContainerHeight: newHeight,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway
        )
    }

    private func deferredContainerRePin(
        distanceToBottom: CGFloat?,
        isInteracting: Bool = false,
        hasInitiallyScrolled: Bool = true, userIsScrolledAway: Bool = false
    ) -> ContainerRePin {
        ConversationTranscriptScrollPolicy.deferredContainerRePinDecision(
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            driftTolerance: 1,
            atBottomThreshold: 50
        )
    }

    /// Regression (#272): a footer row appearing under the transcript shrank
    /// the container (simulator: 757.7 → 677.3 for an 80 pt row) while
    /// `contentOffset` stayed put, so the geometry read 80 pt from the bottom
    /// and Go to End appeared instead of the transcript staying at the end.
    @Test func containerShrinkWhilePinnedRePinsToBottom() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_968, contentOffsetY: 1_188, containerHeight: 780) == 0)
        let shrunk = ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_968, contentOffsetY: 1_188, containerHeight: 700)
        #expect(shrunk == 80)
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(distanceToBottom: shrunk))
        #expect(rePinOnContainerChange(from: 780, to: 700) == .rePin)
    }

    /// The row disappearing grows the container back; a pinned viewport is
    /// re-pinned the other way rather than left past the end.
    @Test func containerGrowthWhilePinnedRePinsToBottom() {
        #expect(rePinOnContainerChange(from: 700, to: 780) == .rePin)
    }

    /// Under the finger the re-pin would fight the pan; a fling released just
    /// before the row lands is still decelerating (the bounce back included)
    /// while the scrolled-away flag has not crossed the threshold yet, and the
    /// re-pin would snap it back. Both defer to the settle re-check instead,
    /// as the #271 past-end clamp does.
    @Test func containerChangeWhileInteractingIsDeferred() {
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 700, to: 780, isInteracting: true) == .deferred)
        #expect(rePinOnContainerChange(from: 780, to: 700, isInteracting: false) == .rePin)
    }

    /// A 36 pt hooks row landing during the bounce back leaves the settled
    /// viewport 36 pt short of the bottom: under the threshold, so no Go to
    /// End and no further edge to close the gap — the settle re-check does.
    /// Still interacting it waits again; a viewport that already rests at
    /// the bottom, or that the fling carried past the threshold (its edge
    /// applied on the way), is left where it is.
    @Test func deferredContainerRePinFollowsOnSettleWithinBottomBand() {
        #expect(deferredContainerRePin(distanceToBottom: 36) == .rePin)
        #expect(deferredContainerRePin(distanceToBottom: 36, isInteracting: true) == .deferred)
        #expect(deferredContainerRePin(distanceToBottom: 0) == .none)
        #expect(deferredContainerRePin(distanceToBottom: -80) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 400) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, userIsScrolledAway: true) == .none)
        #expect(deferredContainerRePin(distanceToBottom: 36, hasInitiallyScrolled: false) == .none)
        #expect(deferredContainerRePin(distanceToBottom: nil) == .none)
    }

    /// Scrolled away, the container resizes at its bottom edge and the content
    /// under the reader does not move (observed in the simulator: the anchored
    /// row kept its frame across both edges), so nothing is adjusted.
    @Test func containerChangeWhileScrolledAwayLeavesContentInPlace() {
        #expect(rePinOnContainerChange(from: 780, to: 700, userIsScrolledAway: true) == .none)
        #expect(rePinOnContainerChange(from: 700, to: 780, userIsScrolledAway: true) == .none)
        #expect(rePinOnContainerChange(
            from: 780, to: 700, isInteracting: true, userIsScrolledAway: true) == .none)
    }

    @Test func unchangedContainerNeverRePins() {
        #expect(rePinOnContainerChange(from: 780, to: 780) == .none)
        #expect(rePinOnContainerChange(from: 780, to: 780, isInteracting: true) == .none)
        #expect(rePinOnContainerChange(from: 780, to: 780, userIsScrolledAway: true) == .none)
    }

    /// Before the entry scroll the viewport is not following yet; the entry
    /// scroll decides where it lands.
    @Test func containerChangeBeforeEntryScrollIsIgnored() {
        #expect(rePinOnContainerChange(from: 780, to: 700, hasInitiallyScrolled: false) == .none)
        #expect(rePinOnContainerChange(
            from: 780, to: 700, hasInitiallyScrolled: false, userIsScrolledAway: true) == .none)
    }

    @Test func followsOnlyAfterEntryScrollWhileAtBottom() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: false,
            userIsScrolledAway: false
        ))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true,
            userIsScrolledAway: false
        ))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true,
            userIsScrolledAway: true
        ))
    }

    /// #280: the observed geometry changes at every band crossing so a flag
    /// edge the observer drops is re-delivered within one band of travel;
    /// the band is sized to the at-bottom threshold.
    @Test func distanceBandStepsAtEveryThreshold() {
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 0, bandHeight: 50) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 46.7, bandHeight: 50) == 0)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 52.7, bandHeight: 50) == 1)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 172.7, bandHeight: 50) == 3)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 210, bandHeight: 50) == 4)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: -10, bandHeight: 50) == -1)
        #expect(ConversationTranscriptScrollPolicy.distanceBand(distanceToBottom: 120)
            == ConversationTranscriptScrollPolicy.distanceBand(
                distanceToBottom: 120,
                bandHeight: Constants.Conversation.Transcript.atBottomThreshold))
    }

    /// #280: a geometry edge clearing the flag (the viewport already at the
    /// bottom, or a transient mid-drag reading) must not start a forced scroll;
    /// only the Go to End tap, which records its request first, does.
    @Test func scrolledAwayClearedFollowsOnlyFromGoToEnd() {
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false))
    }

    /// Ordered regression: a user append raises a forced follow; during its
    /// debounce the user drags away (edge with gesture → away), then a row
    /// re-measures and reads at-bottom for one pass (edge → pinned, #280).
    /// The cleared flag is not a Go to End request, so no second forced
    /// follow is queued, and the one in flight yields at execution instead of
    /// scrolling against the pan.
    @Test func transientAtBottomEdgeMidDragDoesNotRequeueOrExecuteForcedFollow() {
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(!transition(current: true, distanceToBottom: 10, isInteracting: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false))
        #expect(!executeFollow(forced: true, userIsScrolledAway: false, distanceToBottom: 10, isInteracting: true))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
    }

    @Test func streamingStartScrollsOnlyWhileFollowing() {
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true, hasInitiallyScrolled: true, userIsScrolledAway: false))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true, hasInitiallyScrolled: true, userIsScrolledAway: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true, hasInitiallyScrolled: false, userIsScrolledAway: false))
    }

    @Test func streamingEndNeverScrolls() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: false, hasInitiallyScrolled: true, userIsScrolledAway: false))
    }

    private func streamingDelta(
        hasInitiallyScrolled: Bool = true,
        userIsScrolledAway: Bool = false,
        distanceToBottom: CGFloat? = 20,
        now: TimeInterval = 10,
        lastFollowAt: TimeInterval? = nil
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldFollowStreamingDelta(
            hasInitiallyScrolled: hasInitiallyScrolled,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: distanceToBottom,
            now: now,
            lastFollowAt: lastFollowAt,
            driftTolerance: 1,
            atBottomThreshold: 50,
            minimumInterval: 0.5
        )
    }

    @Test func streamingDeltaNeverScrollsWhilePinnedAtBottom() {
        #expect(!streamingDelta(distanceToBottom: 0))
        #expect(!streamingDelta(distanceToBottom: 1))
        #expect(!streamingDelta(distanceToBottom: -30))
    }

    @Test func streamingDeltaRePinsDriftedViewport() {
        #expect(streamingDelta(distanceToBottom: 2))
        #expect(streamingDelta(distanceToBottom: 40))
    }

    @Test func streamingDeltaHonorsFollowGates() {
        #expect(!streamingDelta(hasInitiallyScrolled: false))
        #expect(!streamingDelta(userIsScrolledAway: true, distanceToBottom: 400))
    }

    /// `userIsScrolledAway` lags the geometry; a live distance past the
    /// at-bottom band is treated as scrolled away even while the flag is false.
    @Test func streamingDeltaStaysInsideAtBottomBand() {
        #expect(streamingDelta(distanceToBottom: 50))
        #expect(!streamingDelta(distanceToBottom: 51))
        #expect(!streamingDelta(distanceToBottom: 400))
    }

    @Test func streamingDeltaSkipsUntilScrollViewIsFound() {
        #expect(!streamingDelta(distanceToBottom: nil))
    }

    @Test func streamingDeltaIsRateLimitedToOneScrollPerInterval() {
        #expect(streamingDelta(now: 10, lastFollowAt: nil))
        #expect(!streamingDelta(now: 10, lastFollowAt: 10))
        #expect(!streamingDelta(now: 10.49, lastFollowAt: 10))
        #expect(streamingDelta(now: 10.5, lastFollowAt: 10))
        #expect(streamingDelta(now: 12, lastFollowAt: 10))
    }

    private func executeFollow(
        forced: Bool = false,
        userIsScrolledAway: Bool = false,
        distanceToBottom: CGFloat? = 20,
        isInteracting: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldExecuteFollow(
            forced: forced,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: distanceToBottom,
            isInteracting: isInteracting,
            driftTolerance: 1,
            atBottomThreshold: 50
        )
    }

    /// Regression: a drifted delta requests a follow, then the user scrolls
    /// away during the debounce; the delayed execution must not snap back,
    /// whether the flag has caught up or only the live distance shows it.
    @Test func automaticFollowIsDroppedWhenUserScrolledAwayDuringDebounce() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: 400))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!executeFollow(userIsScrolledAway: false, distanceToBottom: 400))
    }

    @Test func automaticFollowExecutesOnlyInsideAtBottomBand() {
        #expect(executeFollow(distanceToBottom: 50))
        #expect(!executeFollow(distanceToBottom: 51))
    }

    /// Regression: the viewport re-pinned on its own (bottom anchor) while the
    /// follow was debouncing; there is nothing left to scroll.
    @Test func automaticFollowIsDroppedWhenAlreadyPinnedAtExecution() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!executeFollow(distanceToBottom: 0))
        #expect(!executeFollow(distanceToBottom: 1))
        #expect(!executeFollow(distanceToBottom: -30))
        #expect(executeFollow(distanceToBottom: 2))
        #expect(executeFollow(distanceToBottom: nil))
    }

    /// A forced follow is requested pinned, so at execution it lands unless
    /// the user took over meanwhile: a gesture in progress, or one that
    /// already ended having set the flag.
    @Test func forcedFollowExecutesUnlessUserTookOver() {
        #expect(executeFollow(forced: true, distanceToBottom: 400))
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(executeFollow(forced: true, distanceToBottom: nil))
        #expect(!executeFollow(forced: true, distanceToBottom: 400, isInteracting: true))
        #expect(!executeFollow(forced: true, distanceToBottom: 0, isInteracting: true))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 400))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: nil))
    }

    /// Ordered regression: a user append raises a forced follow while pinned;
    /// during its debounce the user drags away and the gesture ends (phase
    /// final sample with the gesture → away) before the follow comes due. The
    /// view cancels the pending follow the moment the gesture is observed
    /// (see `gestureObservedWhileForcedFollowPendingCancelsItImmediately`);
    /// should the task still reach execution or a landing poll first, the
    /// raised flag makes it yield instead of snapping the user back. The viewport stays
    /// away with Go to End showing, nothing re-queues the follow (the flag is
    /// not a Go to End request), and a later Go to End tap is a fresh request.
    @Test func gestureThatEndedAwayDuringForcedFollowDebounceWins() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(transition(current: true, distanceToBottom: 300, isInteracting: false))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 300))
        #expect(landing(geometry(offsetY: 0), userIsScrolledAway: true) == .yieldToUser)
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: false))
        #expect(!executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 300, isInteracting: true))
        #expect(!rePinAfterGrowth(isFollowing: false, userIsScrolledAway: true))
        #expect(transition(current: true, distanceToBottom: 300, isInteracting: false))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true))
        #expect(executeFollow(forced: true, userIsScrolledAway: false, distanceToBottom: 300))
    }

    private func takesOver(isInteracting: Bool, isFollowing: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: isInteracting, isFollowing: isFollowing)
    }

    private func latch(current: Bool = true, distanceToBottom: CGFloat, isInteracting: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.forcedFollowTakeoverLatch(
            current: current,
            geometryAway: ConversationTranscriptScrollPolicy.isScrolledAway(
                distanceToBottom: distanceToBottom, atBottomThreshold: 50),
            isInteracting: isInteracting
        )
    }

    private func honorForced(takenOver: Bool) -> Bool {
        ConversationTranscriptScrollPolicy.shouldHonorForcedFollow(takenOverByGesture: takenOver)
    }

    /// Ordered regression: a forced follow is pending (debounce or landing
    /// loop) when a user gesture is observed — a user-driven phase beginning,
    /// or a geometry edge under UIKit tracking. The follow is taken over and
    /// cancelled at that moment; the gesture then drags away, its final away
    /// edge is dropped by the band observer, and the phase ends (its sample
    /// arriving as "away") before the follow would have come due. Nothing is
    /// left to execute or land, so no scroll is issued; the phase sample
    /// raises the flag and Go to End shows. The takeover is latched, so the
    /// thinking indicator appearing meanwhile does not revive the follow;
    /// Go to End tapped afterwards is a fresh request that clears the latch.
    @Test func gestureObservedWhileForcedFollowPendingCancelsItImmediately() {
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(takesOver(isInteracting: true, isFollowing: true))
        #expect(!takesOver(isInteracting: false, isFollowing: true))
        #expect(!takesOver(isInteracting: true, isFollowing: false))
        // Mid-gesture edges within the threshold keep the pin and the latch.
        #expect(!transition(current: false, distanceToBottom: 20, isInteracting: true))
        #expect(latch(distanceToBottom: 20, isInteracting: true))
        // The final away edge is dropped; the phase ending is the sample.
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(latch(distanceToBottom: 300, isInteracting: false))
        #expect(!honorForced(takenOver: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true, hasInitiallyScrolled: true, userIsScrolledAway: true))
        #expect(!rePinAfterGrowth(isFollowing: false, userIsScrolledAway: true))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(
            goToEndRequested: true))
        #expect(honorForced(takenOver: false))
        #expect(executeFollow(forced: true, distanceToBottom: 300))
    }

    /// The latch releases only once the viewport rests within the threshold
    /// with no gesture in progress: a gesture that ends pinned, or drags back
    /// and lifts, hands the transcript back to content-raised forced follows.
    @Test func forcedFollowTakeoverLatchReleasesWhenTheGestureRestsPinned() {
        #expect(latch(distanceToBottom: 300, isInteracting: true))
        #expect(latch(distanceToBottom: 300, isInteracting: false))
        #expect(latch(distanceToBottom: 0, isInteracting: true))
        #expect(!latch(distanceToBottom: 0, isInteracting: false))
        #expect(!latch(distanceToBottom: 50, isInteracting: false))
        #expect(!latch(current: false, distanceToBottom: 300, isInteracting: true))
        #expect(honorForced(takenOver: false))
    }

    /// The forced-follow gesture predicate is the same one the geometry edges
    /// read: a SwiftUI scroll phase counts as interacting even when the finder
    /// has not resolved a UIScrollView and its flags read false.
    @Test func phaseOnlyInteractionYieldsForcedFollowAndLanding() {
        #expect(!executeFollow(forced: true, distanceToBottom: nil, isInteracting: true))
        #expect(landing(nil, isInteracting: true) == .yieldToUser)
        #expect(transition(current: false, distanceToBottom: 300, isInteracting: true))
    }

    /// Ordered regression: pinned, a streaming delta at distance 20 queues an
    /// automatic follow; during its debounce content grows to distance 100
    /// with no gesture. The growth edge keeps the pin but is not re-pinned
    /// while the follow is in flight; the follow is then dropped as outside
    /// the band. Reconciling the live distance once the follow has drained
    /// must re-pin, so the viewport does not rest short with Go to End hidden.
    @Test func pinnedGrowthDuringAutomaticFollowDebounceRePinsWhenTheFollowDrains() {
        #expect(streamingDelta(distanceToBottom: 20))
        #expect(!transition(current: false, distanceToBottom: 100, isInteracting: false))
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(!executeFollow(distanceToBottom: 100))
        #expect(rePinAfterGrowth(isFollowing: false))
        #expect(!rePinAfterGrowth(geometryAway: false, isFollowing: false))
        #expect(!rePinAfterGrowth(isInteracting: true, isFollowing: false))
    }

    private typealias ViewportGeometry = ConversationTranscriptScrollPolicy.ViewportGeometry
    private typealias LandingStep = ConversationTranscriptScrollPolicy.FollowLandingStep

    /// Geometry of a 1 000 pt transcript in a 700 pt viewport; `offsetY` is
    /// the resting offset (300 is the bottom).
    private func geometry(
        offsetY: CGFloat, contentHeight: CGFloat = 1_000, containerHeight: CGFloat = 700,
        topInset: CGFloat = 0, bottomInset: CGFloat = 0
    ) -> ViewportGeometry {
        ViewportGeometry(
            contentOffsetY: offsetY, contentHeight: contentHeight, containerHeight: containerHeight,
            topInset: topInset, bottomInset: bottomInset)
    }

    /// A landing read that repeats the same geometry (at rest) by default.
    private func landing(
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
            atBottomThreshold: 50,
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
        let roundMilliseconds = Constants.Conversation.Transcript.scrollAnimationDuration * 1_000
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

    private typealias RecoveryStep = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryStep

    /// A recovery poll that repeats the same geometry (at rest) with the end
    /// row unrealized by default.
    private func recovery(
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

    /// Regression (#338): the hooks row landing right after the entry follow
    /// had reported `landed` shrank the container, the container re-pin's
    /// `scrollTo` left the lazy stack with no realized rows, and the geometry
    /// read at the bottom over the blank viewport — `corrections=0`, Go to
    /// End absent, no path fired. A following viewport whose geometry reads
    /// the bottom (the bounce side of the band included) with no end row
    /// realized is paged up one viewport and followed back to the end.
    @Test func blankViewportAtTheBottomIsPagedUpAndFollowedBack() {
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000)) == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_299.5, contentHeight: 3_000)) == .recover(pageOffsetY: 1_599.5))
        #expect(recovery(geometry(offsetY: 2_340, contentHeight: 3_000)) == .recover(pageOffsetY: 1_640))
        // The page up is clamped to the top of the content, under the top
        // inset when there is one.
        #expect(recovery(geometry(offsetY: 300)) == .recover(pageOffsetY: 0))
        #expect(recovery(geometry(offsetY: 50, contentHeight: 750, topInset: 59)) == .recover(pageOffsetY: -59))
    }

    /// A first rest short of the bottom inside the band explains the end
    /// row being off screen and is followed to the end, as the deferred
    /// container re-pin does; a follow that left the geometry unchanged
    /// (the blank can read there too) escalates to the page up.
    @Test func shortRestInsideTheBandIsFollowedOnceThenPagedUp() {
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000)) == .followToEnd)
        #expect(recovery(geometry(offsetY: 2_251, contentHeight: 3_000)) == .followToEnd)
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsSpent: 1)
            == .recover(pageOffsetY: 1_570))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000), correctionsSpent: 1)
            == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_270, contentHeight: 3_000), correctionsLeft: 0) == .giveUp)
    }

    /// The end row realized is the ordinary state at the bottom; nothing is
    /// inferred from the geometry then.
    @Test func realizedEndRowNeedsNoRecovery() {
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true) == .none)
        #expect(recovery(geometry(offsetY: 270), isEndRealized: true) == .none)
        #expect(recovery(geometry(offsetY: 600), isEndRealized: true) == .none)
        #expect(recovery(nil, isEndRealized: true) == .none)
    }

    /// Geometries another path owns are waited out, bounded by the timeout:
    /// past the end the #271 clamp, beyond the band the growth re-pin, each
    /// on its way once its edge fired. Content shorter than the container
    /// realizes every row, so nothing is inferred from it.
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

    /// Verified from two identical reads like a landing; a gesture or a
    /// follow in flight is waited out rather than corrected under.
    @Test func recoveryWaitsForRestAndForGesturesAndFollows() {
        #expect(recovery(nil) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: .some(nil)) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 250)) == .settling)
        #expect(recovery(geometry(offsetY: 300), previous: geometry(offsetY: 300, bottomInset: 20)) == .settling)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true) == .settling)
        #expect(recovery(geometry(offsetY: 300), isFollowing: true) == .settling)
    }

    /// Corrections are bounded by count and by time, and no outcome ever
    /// breaks the pin; a user who scrolled away, or a transcript before its
    /// entry scroll, legitimately has the end row off screen.
    @Test func recoveryIsBoundedAndNeverBreaksThePin() {
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 1) == .recover(pageOffsetY: 0))
        #expect(recovery(geometry(offsetY: 300), correctionsLeft: 0) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), timedOut: true) == .giveUp)
        #expect(recovery(nil, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true) == .none)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, timedOut: true) == .none)
        #expect(recovery(geometry(offsetY: 300), hasInitiallyScrolled: false) == .none)
        #expect(recovery(geometry(offsetY: 300), isEndRealized: true, correctionsLeft: 0) == .none)
        // The recovery's budget is the forced follow's, and the follow's
        // timeout leaves room for every correction to page, follow and
        // settle over two reads.
        let rounds = Double(Constants.Conversation.Transcript.followLandingRetries + 1)
        let roundMilliseconds = Double(3 * Constants.Conversation.Transcript.pastEndSettleMilliseconds)
        #expect(rounds * roundMilliseconds < Double(Constants.Conversation.Transcript.followLandingTimeoutMilliseconds))
    }

    private func mayFollowBack(
        isInteracting: Bool = false,
        userIsScrolledAway: Bool = false,
        isFollowing: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryMayFollowBack(
            isInteracting: isInteracting,
            userIsScrolledAway: userIsScrolledAway,
            isFollowing: isFollowing)
    }

    /// A correction that paged the viewport up follows back only to a
    /// viewport nothing claimed while the rows realized: a gesture that
    /// began meanwhile, a rest it left away, or a follow requested meanwhile
    /// (the user's message, Go to End, content) owns the viewport, and the
    /// correction yields rather than scroll over it. The gesture also takes
    /// the correction over outright, as it does a pending follow.
    @Test func pagedUpRecoveryYieldsToAGestureOrAFollowThatClaimedTheViewport() {
        #expect(mayFollowBack())
        #expect(!mayFollowBack(isInteracting: true))
        #expect(!mayFollowBack(userIsScrolledAway: true))
        #expect(!mayFollowBack(isFollowing: true))
        #expect(!mayFollowBack(isInteracting: true, userIsScrolledAway: true, isFollowing: true))
        #expect(ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: true, isFollowing: true))
        #expect(!ConversationTranscriptScrollPolicy.gestureTakesOverPendingFollow(
            isInteracting: false, isFollowing: true))
        // The yield ends the recovery like a give-up: no further correction
        // is owed to a viewport the user or a follow now owns.
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, correctionsSpent: 1) == .settling)
        #expect(recovery(geometry(offsetY: 300), userIsScrolledAway: true, correctionsSpent: 1) == .none)
        #expect(recovery(geometry(offsetY: 300), isFollowing: true, correctionsSpent: 1) == .settling)
    }

    private typealias RecoveryDrain = ConversationTranscriptScrollPolicy.UnrealizedEndRecoveryDrain

    private func drain(_ outcome: RecoveryStep, isFollowing: Bool = false) -> RecoveryDrain {
        ConversationTranscriptScrollPolicy.unrealizedEndRecoveryDrain(outcome: outcome, isFollowing: isFollowing)
    }

    /// A correction in flight counts as a follow, so the growth re-pin stays
    /// suppressed while it lands; a drain that recovered (the end row
    /// realized) or yielded replays the live edge with the flag released,
    /// so a viewport the correction left short of a realized end row is
    /// re-pinned by the growth path rather than left short with Go to End
    /// hidden, and a yield under the finger reads the edge as the gesture
    /// it is: Go to End shown, no re-pin over it.
    @Test func recoveryDrainReplaysTheEdgeTheCorrectionSuppressed() {
        // Correction in flight: the away edge is neither a scroll away nor a
        // re-pin.
        #expect(!transition(current: false, distanceToBottom: 120, isInteracting: false))
        #expect(!rePinAfterGrowth(isFollowing: true))
        // Recovered — end row realized — at rest short of the end: the pin
        // is kept and followed to the realized row.
        #expect(recovery(geometry(offsetY: 180), isEndRealized: true, correctionsSpent: 1) == .none)
        #expect(drain(.none) == .replayEdge)
        #expect(!transition(current: false, distanceToBottom: 120, isInteracting: false))
        #expect(rePinAfterGrowth(isFollowing: false))
        // Yielded under the finger, short of the end: scrolled away, Go to
        // End shown, nothing scrolls the user back.
        #expect(drain(.yieldToUser) == .replayEdge)
        #expect(transition(current: false, distanceToBottom: 120, isInteracting: true))
        #expect(!rePinAfterGrowth(isInteracting: true))
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
        // Yielded to a follow that claimed the viewport: its landing is the
        // follow's to verify, and the replay re-pins nothing over it.
        #expect(drain(.yieldToUser, isFollowing: true) == .replayEdge)
        #expect(!rePinAfterGrowth(isFollowing: true))
        // Recovered at the bottom: the edge re-pins nothing and clears
        // nothing.
        #expect(!transition(current: false, distanceToBottom: 10, isInteracting: false))
        #expect(!rePinAfterGrowth(geometryAway: false))
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: .yieldToUser, corrections: 1) == "endRecovery=yieldToUser corrections=1")
    }

    /// A give-up leaves the end row unrealized with the budget spent, so a
    /// replayed edge would re-pin blind — a direct scroll to a row that is
    /// not there, with no landing verified and nothing left to arm, leaving
    /// the viewport short with Go to End hidden (the blank in a corner).
    /// The give-up shows Go to End instead, whether the viewport reads
    /// short of the end or at the bottom: the tap follows through the
    /// verified path and re-arms the recovery from the level. A follow in
    /// flight at the give-up owns the viewport and re-arms from its own
    /// drain; flagging the viewport away would cancel it as a takeover.
    @Test func recoveryGiveUpShowsGoToEndInsteadOfRePinningBlind() {
        // Budget spent short of the end inside the band, and timed out at
        // the bottom over the blank: both give up.
        #expect(recovery(geometry(offsetY: 260), correctionsLeft: 0, correctionsSpent: 2) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), correctionsSpent: 2, timedOut: true) == .giveUp)
        #expect(recovery(geometry(offsetY: 300), isInteracting: true, timedOut: true) == .giveUp)
        #expect(drain(.giveUp) == .showGoToEnd)
        // The edge alone would not have shown the button, and would have
        // re-pinned without a gesture — the outcome the give-up overrides.
        #expect(!transition(current: false, distanceToBottom: 40, isInteracting: false))
        #expect(!transition(current: false, distanceToBottom: 0, isInteracting: false))
        #expect(rePinAfterGrowth(isFollowing: false))
        // Scrolled away, the growth path re-pins nothing over the button,
        // and the tap's follow re-arms the recovery from the level.
        #expect(!rePinAfterGrowth(userIsScrolledAway: true))
        #expect(ConversationTranscriptScrollPolicy.shouldFollowOnScrolledAwayCleared(goToEndRequested: true))
        #expect(ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: true, isEndRealized: false))
        // A follow in flight owns the viewport: its drain re-arms.
        #expect(drain(.giveUp, isFollowing: true) == .replayEdge)
        #expect(!rePinAfterGrowth(isFollowing: true))
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: .giveUp, corrections: 2) == "endRecovery=giveUp corrections=2")
    }

    /// An explicit follow cancels a recovery in flight, and the recovery is
    /// otherwise armed only by the end row derealizing — so a follow (Go to
    /// End, the user's message, the entry follow) that executed and drained
    /// with the end row still unrealized re-arms it from the level, or a
    /// viewport that landed blank over an already-unrealized row would
    /// never be recovered. A follow that yielded to the user landed nowhere
    /// and arms nothing; a realized end row needs nothing. The armed
    /// recovery still judges the blank from geometry: a viewport at the
    /// bottom over the unrealized row is paged up, a realized row ends it.
    @Test func followDrainingOverAnUnrealizedEndRowArmsTheRecovery() {
        #expect(ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: true, isEndRealized: false))
        #expect(!ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: true, isEndRealized: true))
        #expect(!ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: false, isEndRealized: false))
        #expect(!ConversationTranscriptScrollPolicy.shouldArmUnrealizedEndRecoveryAfterFollow(
            executed: false, isEndRealized: true))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000)) == .recover(pageOffsetY: 1_600))
        #expect(recovery(geometry(offsetY: 2_300, contentHeight: 3_000), isEndRealized: true) == .none)
    }

    /// The recovery reports next to the forced follow's report under demo
    /// data once it has corrected the viewport, and never on the pending
    /// report the UI tests compare whole.
    @Test func unrealizedEndRecoverySummaryIsAppendedOnlyAfterACorrection() {
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(outcome: nil, corrections: 0) == nil)
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: RecoveryStep.none, corrections: 0) == nil)
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: RecoveryStep.none, corrections: 1) == "endRecovery=recovered corrections=1")
        #expect(ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: .giveUp, corrections: 3) == "endRecovery=giveUp corrections=3")
        let recovered = ConversationTranscriptScrollPolicy.unrealizedEndRecoverySummary(
            outcome: RecoveryStep.none, corrections: 1)
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
            outcome: .landed, corrections: 0, endRecovery: recovered)
            == "lastForcedFollow=landed corrections=0 endRecovery=recovered corrections=1")
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
            outcome: .landed, corrections: 0, endRecovery: nil)
            == "lastForcedFollow=landed corrections=0")
        #expect(ConversationTranscriptScrollPolicy.forcedFollowLandingSummary(
            outcome: nil, corrections: 0, endRecovery: recovered)
            == "lastForcedFollow=pending")
    }

    /// The page up goes through the live scroll view without animation, so
    /// the lazy stack lays out the rows there before the follow back.
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

    /// An unknown distance never releases a scrolled-away state: every
    /// automatic path stays suppressed until the geometry proves otherwise.
    @Test func unknownDistanceDoesNotFlipScrolledAwayBackToPinned() {
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowToBottom(
            hasInitiallyScrolled: true, userIsScrolledAway: true))
        #expect(!streamingDelta(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!executeFollow(userIsScrolledAway: true, distanceToBottom: nil))
        #expect(!ConversationTranscriptScrollPolicy.shouldFollowOnStreamingStateChange(
            isStreaming: true, hasInitiallyScrolled: true, userIsScrolledAway: true))
    }

    @Test func streamingFollowConstantsAreDocumentedDefaults() {
        #expect(Constants.Conversation.Transcript.streamingFollowMinimumInterval > 0)
        #expect(Constants.Conversation.Transcript.streamingFollowDriftTolerance >= 0)
        #expect(Constants.Conversation.Transcript.streamingFollowDriftTolerance
            < Constants.Conversation.Transcript.atBottomThreshold)
    }
}

/// Latch-once-per-viewing-session semantics on ConversationViewModel.
@MainActor
struct ConversationViewModelDividerLatchTests {
    private func makeVM() -> ConversationViewModel {
        ConversationViewModel(
            agentId: "test-agent", workspaceId: "test-ws", agentName: "Test",
            connection: ConnectionManager.shared, uploadService: .shared,
            optionsStore: CreationOptionsStore())
    }

    private func message(_ id: String, role: MessageRole = .assistant) -> ConversationMessage {
        ConversationMessage(
            id: id, role: role,
            contentBlocks: [ContentBlock(type: .text, text: "text for \(id)")]
        )
    }

    @Test func latchesAnchorOnEntryAndExposesIt() {
        let vm = makeVM()
        vm.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        vm.store.lastSeenMessageId = "m2"
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == "m2")
    }

    @Test func markerConvergenceAfterEntryDoesNotMoveDivider() {
        let vm = makeVM()
        vm.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        vm.store.lastSeenMessageId = "m2"
        vm.latchNewMessagesDividerAnchorIfNeeded()
        // Later `agent:updated` convergence advances the marker — the latched
        // divider must not move.
        vm.store.lastSeenMessageId = "m4"
        #expect(vm.newMessagesDividerAnchorId == "m2")
        // New messages arriving never move it either.
        vm.store.messages.append(message("m5"))
        #expect(vm.newMessagesDividerAnchorId == "m2")
        // A repeat latch attempt (e.g. re-entry `load()`) never re-derives.
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == "m2")
    }

    @Test func nilLatchMeansNoDividerAllSession() {
        let vm = makeVM()
        vm.store.messages = ["m1", "m2"].map { message($0) }
        vm.store.lastSeenMessageId = nil
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == nil)
        // Marker converging after entry may not add a divider mid-session.
        vm.store.lastSeenMessageId = "m1"
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == nil)
    }

    @Test func markerAtNewestLatchesNil() {
        let vm = makeVM()
        vm.store.messages = ["m1", "m2"].map { message($0) }
        vm.store.lastSeenMessageId = "m2"
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == nil)
    }

    @Test func anchorTruncatedAwayHidesWithoutRederiving() {
        let vm = makeVM()
        vm.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        vm.store.lastSeenMessageId = "m2"
        vm.latchNewMessagesDividerAnchorIfNeeded()
        #expect(vm.newMessagesDividerAnchorId == "m2")
        // `agent.editAndRegenerate` truncation drops the anchor row. Even with
        // a live marker pointing at a still-present, non-newest message, the
        // divider hides rather than re-deriving to "m1".
        vm.store.messages = ["m1", "m3", "m4"].map { message($0) }
        vm.store.lastSeenMessageId = "m1"
        #expect(vm.newMessagesDividerAnchorId == nil)
    }
}
