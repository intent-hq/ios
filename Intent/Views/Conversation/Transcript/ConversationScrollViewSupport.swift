import Observation
import SwiftUI
import UIKit

/// Stores a weak reference to the underlying UIScrollView so we can stop inertial scrolling.
@Observable
class ScrollViewMomentumProxy {
    @ObservationIgnored weak var scrollView: UIScrollView? {
        didSet { hasResolvedScrollView = scrollView != nil }
    }

    /// Observable edge for "the transcript is hosted": flips when the finder
    /// resolves, so the entry scroll can wait for it instead of a fixed timer.
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

    /// Kills any ongoing deceleration by setting contentOffset to its current value.
    func stopMomentum() {
        AppLog.ui.debug("[SCROLL] stopMomentum called, scrollView=\(scrollView != nil)")
        guard let scrollView else {
            AppLog.ui.warning("[SCROLL] WARNING: scrollView is nil, cannot stop momentum")
            return
        }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        AppLog.ui.debug("[SCROLL] Momentum stopped at offset \(scrollView.contentOffset)")
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

    func makeUIView(context: Context) -> FinderView {
        let view = FinderView()
        view.isUserInteractionEnabled = false
        view.frame = .zero
        view.proxy = proxy
        return view
    }

    func updateUIView(_ uiView: FinderView, context: Context) {
        uiView.proxy = proxy
    }

    final class FinderView: UIView {
        var proxy: ScrollViewMomentumProxy?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            resolveScrollView()
        }

        private func resolveScrollView() {
            guard let proxy else { return }
            guard let scrollView = ScrollViewFinder.firstScrollViewAncestor(of: self) else {
                AppLog.ui.warning("[SCROLL] WARNING: Could not find UIScrollView in hierarchy")
                return
            }
            if proxy.scrollView !== scrollView {
                proxy.scrollView = scrollView
                AppLog.ui.debug("[SCROLL] Found UIScrollView: \(scrollView)")
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
                to: nil, from: nil, for: nil
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
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