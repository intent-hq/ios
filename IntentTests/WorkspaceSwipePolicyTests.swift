import Foundation
@testable import Intent
import Testing

struct WorkspaceSwipePolicyTests {
    private static let leadingWidth: CGFloat = 168
    private static let trailingWidth: CGFloat = 136

    @Test func rightSwipeFollowsTheFingerAndRequiresTheFullDistance() {
        let partial: CGFloat = 80
        #expect(WorkspaceSwipePolicy.offset(
            translation: partial,
            origin: 0,
            leadingWidth: Self.leadingWidth,
            trailingWidth: Self.trailingWidth
        ) == partial)
        #expect(!WorkspaceSwipePolicy.completesLeadingSwipe(translation: partial, origin: 0, leadingWidth: Self.leadingWidth))
        #expect(WorkspaceSwipePolicy.completesLeadingSwipe(translation: Self.leadingWidth, origin: 0, leadingWidth: Self.leadingWidth))
    }

    @Test func retreatingBeforeReleaseDoesNotCompleteTheSwipe() {
        let retreat: CGFloat = 120
        #expect(!WorkspaceSwipePolicy.completesLeadingSwipe(translation: retreat, origin: 0, leadingWidth: Self.leadingWidth))
        #expect(!WorkspaceSwipePolicy.completesLeadingSwipe(translation: -Self.leadingWidth, origin: 0, leadingWidth: Self.leadingWidth))
    }

    @Test func rightSwipeFromOpenTrailingActionsOnlyClosesThem() {
        let longSwipe: CGFloat = 400
        #expect(WorkspaceSwipePolicy.offset(
            translation: longSwipe,
            origin: -Self.trailingWidth,
            leadingWidth: Self.leadingWidth,
            trailingWidth: Self.trailingWidth
        ) == 0)
        #expect(!WorkspaceSwipePolicy.completesLeadingSwipe(
            translation: longSwipe,
            origin: -Self.trailingWidth,
            leadingWidth: Self.leadingWidth
        ))
    }

    @Test func existingContainersWithoutALeadingActionCannotSwipeRight() {
        #expect(WorkspaceSwipePolicy.offset(
            translation: Self.leadingWidth,
            origin: 0,
            leadingWidth: 0,
            trailingWidth: Self.trailingWidth
        ) == 0)
        #expect(!WorkspaceSwipePolicy.completesLeadingSwipe(translation: Self.leadingWidth, origin: 0, leadingWidth: 0))
        #expect(WorkspaceSwipePolicy.offset(
            translation: -Self.leadingWidth,
            origin: 0,
            leadingWidth: 0,
            trailingWidth: Self.trailingWidth
        ) == -Self.trailingWidth)
    }
}
