import Foundation

enum WorkspaceSwipePolicy {
    struct LeadingLayout {
        let maximumBadgeWidth: CGFloat
        let revealWidth: CGFloat
    }

    private static let maximumSwipeFraction: CGFloat = 0.7

    static func leadingLayout(rowWidth: CGFloat, badgeWidth: CGFloat, leadingInset: CGFloat, gap: CGFloat) -> LeadingLayout {
        let travelLimit = max(0, rowWidth * maximumSwipeFraction)
        let maximumBadgeWidth = max(0, travelLimit - leadingInset - gap)
        return LeadingLayout(
            maximumBadgeWidth: maximumBadgeWidth,
            revealWidth: min(travelLimit, min(badgeWidth, maximumBadgeWidth) + leadingInset + gap)
        )
    }

    static func offset(translation: CGFloat, origin: CGFloat, leadingWidth: CGFloat, trailingWidth: CGFloat) -> CGFloat {
        let leadingLimit = origin < 0 ? 0 : max(0, leadingWidth)
        return min(leadingLimit, max(-trailingWidth, origin + translation))
    }

    static func completesLeadingSwipe(translation: CGFloat, origin: CGFloat, leadingWidth: CGFloat) -> Bool {
        leadingWidth > 0 && origin >= 0 && origin + translation >= leadingWidth
    }
}
