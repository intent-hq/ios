import Foundation
@testable import Intent
import Testing

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
            messageIds: ids,
            lastSeenMessageId: "truncated-away"
        ) == nil)
    }

    @Test func nilForEmptyTranscript() {
        #expect(NewMessagesDivider.resolveAnchor(messageIds: [], lastSeenMessageId: "m1") == nil)
    }
}

struct NewMessagesDividerLatchedTests {
    private let ids = ["m1", "m2", "m3", "m4"]

    @Test func rendersAtLatchedAnchorWhilePresent() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids,
            latchedAnchorId: "m2"
        ) == "m2")
    }

    @Test func keepsLatchedAnchorEvenWhenNewest() {
        // The entry-time resolver never latches the newest message, but a
        // latched anchor that BECAME newest (trailing rows truncated) still
        // renders as-is.
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids,
            latchedAnchorId: "m4"
        ) == "m4")
    }

    @Test func staysPutAsTranscriptGrows() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids,
            latchedAnchorId: "m2"
        ) == "m2")
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ids + ["m5", "m6"],
            latchedAnchorId: "m2"
        ) == "m2")
    }

    @Test func nilForNilLatch() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: ids, latchedAnchorId: nil) == nil)
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: ids, latchedAnchorId: "") == nil)
    }

    @Test func hidesNotRecomputesWhenAnchorLeftTranscript() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(
            messageIds: ["m1", "m3", "m4"],
            latchedAnchorId: "m2"
        ) == nil)
    }

    @Test func nilForEmptyTranscript() {
        #expect(NewMessagesDivider.resolveLatchedAnchor(messageIds: [], latchedAnchorId: "m2") == nil)
    }
}

/// Entry-scroll follow decision in the flipped list (contentOffset.y ≈ 0 is
/// the visual bottom; threshold mirrors the list's at-bottom detection).
struct NewMessagesDividerEntryScrollTests {
    @Test func followStaysEnabledWhenClampedAtBottom() {
        // Unseen tail fits on screen: the divider scroll clamps at the
        // bottom, so follow-to-bottom keeps today's behavior.
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: 0))
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: 50))
    }

    @Test func followStaysEnabledAtSafeAreaRestingOffset() {
        // A scroll view at rest can sit at a negative offset (adjusted
        // content inset) — still the visual bottom.
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: -59))
    }

    @Test func followDisabledWhenLandedOnDividerAwayFromBottom() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: 51))
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(flippedContentOffsetY: 2000))
    }

    @Test func honorsCustomThreshold() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(
            flippedContentOffsetY: 30,
            atBottomThreshold: 10
        ))
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(
            flippedContentOffsetY: 30,
            atBottomThreshold: 100
        ))
    }
}

struct ConversationTranscriptScrollPolicyTests {
    @Test func tracksAwayStateAcrossBottomThreshold() {
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(flippedContentOffsetY: -20))
        #expect(!ConversationTranscriptScrollPolicy.isScrolledAway(flippedContentOffsetY: 50))
        #expect(ConversationTranscriptScrollPolicy.isScrolledAway(flippedContentOffsetY: 51))
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
            agentId: "test-agent",
            workspaceId: "test-ws",
            agentName: "Test",
            connection: ConnectionManager.shared,
            uploadService: .shared
        )
    }

    private func message(_ id: String, role: MessageRole = .assistant) -> ConversationMessage {
        ConversationMessage(
            id: id,
            role: role,
            contentBlocks: [ContentBlock(type: .text, text: "text for \(id)")]
        )
    }

    @Test func latchesAnchorOnEntryAndExposesIt() {
        let viewModel = makeVM()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
    }

    @Test func markerConvergenceAfterEntryDoesNotMoveDivider() {
        let viewModel = makeVM()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        // Later `agent:updated` convergence advances the marker — the latched
        // divider must not move.
        viewModel.store.lastSeenMessageId = "m4"
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        // New messages arriving never move it either.
        viewModel.store.messages.append(message("m5"))
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        // A repeat latch attempt (e.g. re-entry `load()`) never re-derives.
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
    }

    @Test func nilLatchMeansNoDividerAllSession() {
        let viewModel = makeVM()
        viewModel.store.messages = ["m1", "m2"].map { message($0) }
        viewModel.store.lastSeenMessageId = nil
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
        // Marker converging after entry may not add a divider mid-session.
        viewModel.store.lastSeenMessageId = "m1"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }

    @Test func markerAtNewestLatchesNil() {
        let viewModel = makeVM()
        viewModel.store.messages = ["m1", "m2"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }

    @Test func anchorTruncatedAwayHidesWithoutRederiving() {
        let viewModel = makeVM()
        viewModel.store.messages = ["m1", "m2", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m2"
        viewModel.latchNewMessagesDividerAnchorIfNeeded()
        #expect(viewModel.newMessagesDividerAnchorId == "m2")
        // `agent.editAndRegenerate` truncation drops the anchor row. Even with
        // a live marker pointing at a still-present, non-newest message, the
        // divider hides rather than re-deriving to "m1".
        viewModel.store.messages = ["m1", "m3", "m4"].map { message($0) }
        viewModel.store.lastSeenMessageId = "m1"
        #expect(viewModel.newMessagesDividerAnchorId == nil)
    }
}
