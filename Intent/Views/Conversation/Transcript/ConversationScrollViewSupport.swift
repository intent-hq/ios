import Observation
import SwiftUI
import UIKit

@Observable
class ScrollViewMomentumProxy {
    @ObservationIgnored weak var scrollView: UIScrollView? {
        didSet { hasResolvedScrollView = scrollView != nil }
    }

    private(set) var hasResolvedScrollView = false
    private(set) var hostingRevision = 0

    func didAttachToWindow() { hostingRevision &+= 1 }

    var distanceToBottom: CGFloat? {
        guard let scrollView else { return nil }
        return ConversationTranscriptScrollPolicy.distanceToBottom(
            contentHeight: scrollView.contentSize.height,
            contentOffsetY: scrollView.contentOffset.y,
            containerHeight: scrollView.bounds.height,
            bottomInset: scrollView.adjustedContentInset.bottom
        )
    }

    func rePinIfRestingPastEnd(confirming: RestingGeometry?, isFollowing: Bool = false) -> RePinOutcome {
        guard let scrollView, let geometry = restingGeometry else {
            ConversationTrace.emit("RePinSkipped", "reason=noScrollView")
            return .unavailable
        }
        let decision = ConversationTranscriptScrollPolicy.rePinDecision(
            contentOffsetY: geometry.contentOffsetY,
            distanceToBottom: geometry.distanceToBottom,
            isInteracting: isFollowing || isInteracting,
            contentHeight: geometry.contentHeight,
            containerHeight: geometry.containerHeight,
            verticalInsets: geometry.verticalInsets
        )
        ConversationTrace.emit("RePinDecision", "host=\(ObjectIdentifier(scrollView)) decision=\(decision) geometry=\(geometry) confirmed=\(geometry == confirming) following=\(isFollowing)")
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

    var isInteracting: Bool {
        guard let scrollView else { return false }
        return scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating
    }

    typealias RestingGeometry = ConversationTranscriptScrollPolicy.ViewportGeometry

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
        case deferred(RestingGeometry?)
        case unavailable
    }

    @discardableResult
    func pageTo(offsetY: CGFloat) -> Bool {
        guard let scrollView else {
            ConversationTrace.emit("PageSkipped", "reason=noScrollView target=\(offsetY)")
            return false
        }
        ConversationTrace.emit("PageRequested", "host=\(ObjectIdentifier(scrollView)) from=\(scrollView.contentOffset.y) target=\(offsetY)")
        AppLog.userInterface.debug("[SCROLL] Paging blank viewport from \(scrollView.contentOffset.y) to \(offsetY)")
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: offsetY), animated: false)
        return true
    }

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
            proxy.didAttachToWindow()
        }
    }

    private final class KeyboardDismissTapGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            addTarget(self, action: #selector(handleTap))
            cancelsTouchesInView = false
            delegate = self
        }

        @objc private func handleTap() {
            DispatchQueue.main.async {
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder),
                    to: nil,
                    from: nil,
                    for: nil
                )
            }
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
