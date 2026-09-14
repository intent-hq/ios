import Foundation
import Testing
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

struct ConversationTranscriptScrollPolicyTests {
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

    private func resolved(
        live: Bool, current: Bool,
        hasInitiallyScrolled: Bool = true, isScrollingToBottom: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.resolvedScrolledAway(
            live: live, current: current,
            hasInitiallyScrolled: hasInitiallyScrolled,
            isScrollingToBottom: isScrollingToBottom)
    }

    @Test func scrolledAwayFollowsLiveGeometryWhileGateIsOpen() {
        #expect(resolved(live: true, current: false))
        #expect(!resolved(live: false, current: true))
        #expect(resolved(live: true, current: true))
        #expect(!resolved(live: false, current: false))
    }

    @Test func scrolledAwayIsFrozenWhileGateIsClosed() {
        #expect(!resolved(live: true, current: false, hasInitiallyScrolled: false))
        #expect(resolved(live: false, current: true, hasInitiallyScrolled: false))
        #expect(!resolved(live: true, current: false, isScrollingToBottom: true))
        #expect(resolved(live: false, current: true, isScrollingToBottom: true))
    }

    /// Regression: the geometry's only "scrolled away" edge landed while the
    /// gate was closed (entry scroll) and was dropped; later user scrolls
    /// produced no new edge, so Go to End never showed. Re-applying the
    /// retained live value when the gate opens recovers it.
    @Test func gateOpeningWhileAlreadyScrolledAwayAppliesLiveValue() {
        #expect(!resolved(live: true, current: false, hasInitiallyScrolled: false))
        #expect(resolved(live: true, current: false, hasInitiallyScrolled: true))
        // The same after a forced follow ends with the user having dragged
        // away mid-scroll, and the converse when it landed at the bottom.
        #expect(!resolved(live: true, current: false, isScrollingToBottom: true))
        #expect(resolved(live: true, current: false, isScrollingToBottom: false))
        #expect(!resolved(live: false, current: false, isScrollingToBottom: false))
    }

    @Test func distanceToBottomIsNegativeForShortContentAndOverscroll() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 400, contentOffsetY: 0, containerHeight: 700) == -300)
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_000, contentOffsetY: 360, containerHeight: 700) == -60)
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
        distanceToBottom: CGFloat? = 20
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldExecuteFollow(
            forced: forced,
            userIsScrolledAway: userIsScrolledAway,
            distanceToBottom: distanceToBottom,
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

    @Test func forcedFollowAlwaysExecutes() {
        #expect(executeFollow(forced: true, userIsScrolledAway: true, distanceToBottom: 400))
        #expect(executeFollow(forced: true, distanceToBottom: 0))
        #expect(executeFollow(forced: true, distanceToBottom: nil))
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
            connection: ConnectionManager.shared, uploadService: .shared)
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
