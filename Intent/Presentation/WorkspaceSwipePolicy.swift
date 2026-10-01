import Foundation

enum WorkspaceSwipePolicy {
    static func offset(translation: CGFloat, origin: CGFloat, leadingWidth: CGFloat, trailingWidth: CGFloat) -> CGFloat {
        let leadingLimit = origin < 0 ? 0 : max(0, leadingWidth)
        return min(leadingLimit, max(-trailingWidth, origin + translation))
    }

    static func completesLeadingSwipe(translation: CGFloat, origin: CGFloat, leadingWidth: CGFloat) -> Bool {
        leadingWidth > 0 && origin >= 0 && origin + translation >= leadingWidth
    }
}
