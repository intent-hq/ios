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
