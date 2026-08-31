import CoreGraphics

enum ConversationTranscriptScrollPolicy {
    static func isScrolledAway(
        flippedContentOffsetY: CGFloat,
        atBottomThreshold: CGFloat = 50
    ) -> Bool {
        flippedContentOffsetY > atBottomThreshold
    }

    static func shouldFollowToBottom(
        hasInitiallyScrolled: Bool,
        userIsScrolledAway: Bool
    ) -> Bool {
        hasInitiallyScrolled && !userIsScrolledAway
    }
}