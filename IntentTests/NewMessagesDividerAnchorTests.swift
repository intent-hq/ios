import Foundation
@testable import Intent
import Testing
import UIKit

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
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: 2000))
    }

    /// Regression: an unknown distance after landing on the divider must not
    /// be read as bottom-pinned (which hid Go to End and let a later follow
    /// pull the user off the divider).
    @Test func followDisabledWhenDistanceIsUnknownAfterDividerLanding() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(distanceToBottom: nil))
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: nil,
            atBottomThreshold: 10_000
        ))
    }

    @Test func honorsCustomThreshold() {
        #expect(NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: 30,
            atBottomThreshold: 10
        ))
        #expect(!NewMessagesDivider.followDisabledAfterEntryScroll(
            distanceToBottom: 30,
            atBottomThreshold: 100
        ))
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
