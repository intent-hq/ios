import Foundation
@testable import Intent
import Observation
import SwiftUI
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
        let firstHosting = proxy.hostingRevision
        let tapCount = { scrollView.gestureRecognizers?.count ?? 0 }
        let installed = tapCount()

        // Re-attaching re-runs the walk without duplicating the gesture.
        scrollView.removeFromSuperview()
        window.addSubview(scrollView)
        #expect(proxy.scrollView === scrollView)
        #expect(tapCount() == installed)
        #expect(proxy.hostingRevision > firstHosting, "the same UIScrollView returning must announce a new hosting edge")
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

@Suite @MainActor
struct TranscriptRowHeightFrameTests {
    private static let cachedHeight: CGFloat = 100
    private static let grownHeight: CGFloat = 200
    private static let shrunkHeight: CGFloat = 60
    private static let viewportSize = CGSize(width: 320, height: 400)

    @Test func cachedFrameKeepsObservingLateNaturalGrowthAndShrink() async throws {
        let source = HostedTranscriptHeightSource(height: Self.cachedHeight)
        let recorder = HostedTranscriptHeightRecorder()
        let host = HostedTranscriptHeightProbe(source: source, recorder: recorder)
        defer { host.tearDown() }

        try await waitUntil("initial natural and framed heights") {
            recorder.naturalHeight == Self.cachedHeight && recorder.rowHeight == Self.cachedHeight
        }

        source.height = Self.grownHeight
        host.layout()
        try await waitUntil("late intrinsic growth") {
            recorder.contentHeight == Self.grownHeight && recorder.naturalHeight == Self.grownHeight
        }
        #expect(recorder.rowHeight == Self.cachedHeight)

        source.height = Self.shrunkHeight
        host.layout()
        try await waitUntil("late intrinsic shrink") {
            recorder.contentHeight == Self.shrunkHeight && recorder.naturalHeight == Self.shrunkHeight
        }
        #expect(recorder.rowHeight == Self.cachedHeight)
    }

    @Test func stableNaturalHeightIsReportedWhenStreamingCompletes() async throws {
        let source = HostedTranscriptHeightSource(height: Self.cachedHeight, isStreaming: true)
        let recorder = HostedTranscriptHeightRecorder()
        let host = HostedTranscriptHeightProbe(source: source, recorder: recorder)
        defer { host.tearDown() }

        try await waitUntil("initial streaming measurement") {
            recorder.naturalHeightChanges > 0
        }
        let streamingMeasurements = recorder.naturalHeightChanges

        source.isStreaming = false
        host.layout()
        try await waitUntil("terminal-state measurement") {
            recorder.naturalHeightChanges > streamingMeasurements
        }
        #expect(recorder.naturalHeight == Self.cachedHeight)
    }

    @Observable
    final class HeightSource {
        var height: CGFloat
        var isStreaming: Bool

        init(height: CGFloat, isStreaming: Bool = false) {
            self.height = height
            self.isStreaming = isStreaming
        }
    }

    private typealias HostedTranscriptHeightSource = HeightSource

    private final class HeightRecorder {
        var contentHeight: CGFloat?
        var naturalHeight: CGFloat?
        var naturalHeightChanges = 0
        var rowHeight: CGFloat?
    }

    private typealias HostedTranscriptHeightRecorder = HeightRecorder

    private struct HeightProbe: View {
        let source: HeightSource
        let recorder: HeightRecorder

        var body: some View {
            Color.clear
                .frame(height: source.height)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    recorder.contentHeight = height
                }
                .modifier(
                    ConversationTranscriptRowHeightFrame(
                        cachedHeight: TranscriptRowHeightFrameTests.cachedHeight,
                        isStreaming: source.isStreaming
                    ) { height in
                        recorder.naturalHeight = height
                        recorder.naturalHeightChanges += 1
                    }
                )
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    recorder.rowHeight = height
                }
        }
    }

    private final class HostedTranscriptHeightProbe {
        private var controller: UIHostingController<HeightProbe>?
        private var window: UIWindow?

        init(source: HeightSource, recorder: HeightRecorder) {
            let controller = UIHostingController(
                rootView: HeightProbe(source: source, recorder: recorder)
            )
            let window = UIWindow(
                frame: CGRect(origin: .zero, size: TranscriptRowHeightFrameTests.viewportSize)
            )
            controller.view.frame = window.bounds
            controller.beginAppearanceTransition(true, animated: false)
            window.addSubview(controller.view)
            window.isHidden = false
            controller.endAppearanceTransition()
            self.controller = controller
            self.window = window
            layout()
        }

        func layout() {
            controller?.view.setNeedsLayout()
            controller?.view.layoutIfNeeded()
        }

        func tearDown() {
            guard let controller, let window else { return }
            controller.beginAppearanceTransition(false, animated: false)
            controller.view.removeFromSuperview()
            window.isHidden = true
            controller.endAppearanceTransition()
            self.controller = nil
            self.window = nil
        }
    }
}
