import Observation
import SwiftUI
import UIKit

/// Stores a weak reference to the underlying UIScrollView so we can stop inertial scrolling.
@Observable
class ScrollViewMomentumProxy {
    @ObservationIgnored weak var scrollView: UIScrollView? {
        didSet { hasResolvedScrollView = scrollView != nil }
    }

    /// Observable edge for "the transcript has been hosted": flips when the
    /// finder resolves, so the entry scroll can wait for it instead of a fixed
    /// timer. Sticky, not a liveness signal: weak zeroing skips `didSet`, so
    /// it stays true after the scroll view deallocates while `scrollView` and
    /// `distanceToBottom` are nil again.
    private(set) var hasResolvedScrollView = false

    /// Gap between the viewport's bottom edge and the end of the content, or
    /// nil before the scroll view has been found.
    var distanceToBottom: CGFloat? {
        guard let scrollView else { return nil }
        return ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: scrollView.contentSize.height,
            contentOffsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    /// Re-pins a viewport resting past the end of the content to the bottom
    /// (#271). Reads the live UIScrollView rather than the geometry edge that
    /// scheduled it: a bounce or a mid-animation frame reads past the end too
    /// and must settle on its own (`.deferred`). The lazy stack also re-lays
    /// out several times per frame while the keyboard animates, reading past
    /// the end in some passes and not others, so a re-pin is only applied
    /// once the same resting geometry has been read twice — pass the
    /// geometry a `.deferred` outcome carries back on the next check. A
    /// programmatic follow (`isFollowing`) animates through the same geometry
    /// and is deferred like a gesture, so the clamp cannot land mid-animation.
    /// `.unavailable` when the scroll view has not been found, so the caller
    /// can fall back.
    func rePinIfRestingPastEnd(confirming: RestingGeometry?, isFollowing: Bool = false) -> RePinOutcome {
        guard let scrollView, let geometry = restingGeometry else { return .unavailable }
        let decision = ConversationTranscriptScrollPolicy.rePinDecision(
            contentOffsetY: geometry.contentOffsetY,
            distanceToBottom: geometry.distanceToBottom,
            isInteracting: isFollowing || isInteracting,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            verticalInsets: geometry.verticalInsets
        )
        switch decision {
        case .none:
            return .notPastEnd
        case .deferred:
            return .deferred(nil)
        case .rePin(let offsetY):
            guard geometry == confirming else { return .deferred(geometry) }
            AppLog.userInterface.debug("[SCROLL] Re-pinning past-end viewport from \(geometry.contentOffsetY) to \(offsetY)")
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
            return .rePinned
        }
    }

    /// True while the user's finger is on the scroll view or a fling is
    /// still decelerating (the bounce back included); false before the
    /// scroll view has been found.
    var isInteracting: Bool {
        guard let scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    typealias RestingGeometry = ConversationTranscriptScrollPolicy.ViewportGeometry

    /// One read of everything the landing and re-pin decisions compare, or
    /// nil before the scroll view has been found.
    var restingGeometry: RestingGeometry? {
        guard let scrollView else { return nil }
        let insets = scrollView.adjustedContentInset
        return RestingGeometry(
            contentOffsetY: scrollView.contentOffset.y,
            contentHeight: scrollView.contentSize.height,
            containerHeight: scrollView.bounds.height,
            topInset: insets.top,
            bottomInset: insets.bottom
        )
    }

    enum RePinOutcome: Equatable {
        case rePinned
        case notPastEnd
        /// Past the end but still dragging, decelerating or following (nil),
        /// or read past the end for the first time; check again later.
        case deferred(RestingGeometry?)
        case unavailable
    }

    /// Moves a resting viewport to `offsetY` without animation, so the lazy
    /// stack lays out the rows there before a follow back to the end (#338);
    /// false when the scroll view has not been found.
    @discardableResult
    func pageTo(offsetY: CGFloat) -> Bool {
        guard let scrollView else { return false }
        AppLog.userInterface.debug("[SCROLL] Paging blank viewport from \(scrollView.contentOffset.y) to \(offsetY)")
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
        return true
    }

    /// Kills any ongoing deceleration by setting contentOffset to its current value.
    func stopMomentum() {
        AppLog.userInterface.debug("[SCROLL] stopMomentum called, scrollView=\(scrollView != nil)")
        guard let scrollView else {
            AppLog.userInterface.warning("[SCROLL] WARNING: scrollView is nil, cannot stop momentum")
            return
        }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        AppLog.userInterface.debug("[SCROLL] Momentum stopped at offset \(scrollView.contentOffset)")
    }
}

/// A zero-size UIView that walks up the view hierarchy to find the enclosing UIScrollView.
///
/// The walk runs from `didMoveToWindow`, not from `makeUIView`: when the
/// representable is created its only ancestor is SwiftUI's platform-view
/// host and it has no window yet, so an eager walk stops one hop up and
/// never reaches the scroll view. Attaching to a window guarantees the full
/// ancestor chain exists, and re-attaching (e.g. after a hosting change)
/// re-runs the walk idempotently.
struct ScrollViewFinder: UIViewRepresentable {
    let proxy: ScrollViewMomentumProxy

    func makeUIView(context _: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.frame = .zero
        view.proxy = proxy
        return view
    }

    func updateUIView(_ uiView: FinderView, context _: Context) {
        uiView.proxy = proxy
    }

    final class FinderView: UIView {
        /// A proxy swapped in while already hosted is resolved immediately;
        /// otherwise resolution waits for the window attach.
        var proxy: ScrollViewMomentumProxy? {
            didSet {
                guard proxy !== oldValue, window != nil else { return }
                resolveScrollView()
            }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            resolveScrollView()
        }

        private func resolveScrollView() {
            guard let proxy else { return }
            guard let scrollView = ScrollViewFinder.firstScrollViewAncestor(of: self) else {
                AppLog.userInterface.warning("[SCROLL] WARNING: Could not find UIScrollView in hierarchy")
                return
            }
            if proxy.scrollView !== scrollView {
                proxy.scrollView = scrollView
                AppLog.userInterface.debug("[SCROLL] Found UIScrollView: \(scrollView)")
            }
            ScrollViewFinder.installKeyboardDismissTap(on: scrollView)
        }
    }

    /// Installed directly on the transcript scroll view so SwiftUI's hosting
    /// recognizer does not starve UIKit link-tap recognizers in message content.
    private final class KeyboardDismissTapGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            addTarget(self, action: #selector(handleTap))
            cancelsTouchesInView = false
            delegate = self
        }

        @objc private func handleTap() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil,
                from: nil,
                for: nil
            )
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    private static func installKeyboardDismissTap(on scrollView: UIScrollView) {
        guard !hasKeyboardDismissTap(scrollView) else { return }
        scrollView.addGestureRecognizer(KeyboardDismissTapGesture())
    }

    static func hasKeyboardDismissTap(_ scrollView: UIScrollView) -> Bool {
        scrollView.gestureRecognizers?.contains { $0 is KeyboardDismissTapGesture } == true
    }

    /// The nearest `UIScrollView` strictly above `view` in the superview
    /// chain, or nil when the chain ends without one.
    static func firstScrollViewAncestor(of view: UIView) -> UIScrollView? {
        var current: UIView? = view
        while let parent = current?.superview {
            if let scrollView = parent as? UIScrollView {
                return scrollView
            }
            current = parent
        }
        return nil
    }
}
