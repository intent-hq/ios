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

    @Test func distanceToBottomGrowsAsViewportScrollsUp() {
        #expect(ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: 1_000, contentOffsetY: 100, containerHeight: 700) == 200)
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
