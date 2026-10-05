import Foundation
@testable import Intent
import Testing

struct ConversationTranscriptHistoryPolicyTests {
    @Test(arguments: [false, true])
    func prependPreservesViewportInsteadOfFollowingOrRearming(hasInitiallyScrolled: Bool) {
        let old = ["assistant", "user"]
        let prepended = ["earlier"] + old
        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: old.count,
            to: prepended.count,
            hasInitiallyScrolled: hasInitiallyScrolled,
            isPrepend: ConversationTranscriptScrollPolicy.isHistoryPrepend(from: old, to: prepended)
        ) == .preserveViewport)
    }

    @Test(arguments: [["assistant", "user", "reply"], ["earlier", "assistant", "user", "reply"], ["replacement", "user"]])
    func liveTailChangesAreNotHistoryPrepends(newIDs: [String]) {
        #expect(!ConversationTranscriptScrollPolicy.isHistoryPrepend(from: ["assistant", "user"], to: newIDs))
    }

    @Test func firstSnapshotRemainsAnEntryScroll() {
        let messages = ["first"]
        #expect(ConversationTranscriptScrollPolicy.messageCountChangeDecision(
            from: 0,
            to: messages.count,
            hasInitiallyScrolled: false,
            isPrepend: ConversationTranscriptScrollPolicy.isHistoryPrepend(from: [], to: messages)
        ) == .runEntryScroll)
    }

    @Test func historyWaitsForUserEntryAndDoesNotAutomaticallyRetry() {
        #expect(shouldLoad())
        #expect(!shouldLoad(isNearTop: false))
        #expect(!shouldLoad(hasInitiallyScrolled: false))
        #expect(!shouldLoad(hasUserScrolled: false))
        #expect(!shouldLoad(isFollowing: true))
        #expect(!shouldLoad(hasOlderMessages: false))
        #expect(!shouldLoad(isLoading: true))
        #expect(!shouldLoad(hasError: true))
    }

    @Test(arguments: [CGFloat(400), 800])
    func historyPrefetchScalesWithViewportAndIncludesTheTopInset(height: CGFloat) {
        let topInset: CGFloat = 64
        #expect(ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: height * 2, topInset: topInset, viewportHeight: height))
        #expect(ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: height * 3 - topInset, topInset: topInset, viewportHeight: height))
        #expect(!ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: height * 3 - topInset + 1, topInset: topInset, viewportHeight: height))
        #expect(ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: -topInset - 1, topInset: topInset, viewportHeight: height))
    }

    @Test func unavailableHistoryGeometryDoesNotPrefetch() {
        #expect(!ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: 0, topInset: 0, viewportHeight: 0))
        #expect(!ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: 0, topInset: 0, viewportHeight: .infinity))
        #expect(!ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: .nan, topInset: 0, viewportHeight: 600))
        #expect(!ConversationTranscriptScrollPolicy.isNearHistoryTop(contentOffsetY: 0, topInset: .nan, viewportHeight: 600))
    }

    private func shouldLoad(
        isNearTop: Bool = true,
        hasInitiallyScrolled: Bool = true,
        hasUserScrolled: Bool = true,
        isFollowing: Bool = false,
        hasOlderMessages: Bool = true,
        isLoading: Bool = false,
        hasError: Bool = false
    ) -> Bool {
        ConversationTranscriptScrollPolicy.shouldLoadOlderMessages(
            isNearTop: isNearTop,
            hasInitiallyScrolled: hasInitiallyScrolled,
            hasUserScrolled: hasUserScrolled,
            isFollowing: isFollowing,
            canRequestPage: hasOlderMessages && !isLoading && !hasError
        )
    }
}
