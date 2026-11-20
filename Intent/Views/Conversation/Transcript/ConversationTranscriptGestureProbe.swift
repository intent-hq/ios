import UIKit

final class TranscriptGestureAccessibilityView: UIView {
    weak var scrollState: ConversationTranscriptScrollState?

    override var accessibilityValue: String? {
        get {
            guard let scrollState, let scrollView = scrollState.momentumProxy.scrollView else {
                return "phase=unresolved"
            }
            let tracking = scrollView.isTracking
            let dragging = scrollView.isDragging
            let decelerating = scrollView.isDecelerating
            let swiftUI = scrollState.isUserScrollPhase
            let interacting = tracking || dragging || decelerating || swiftUI
            return "phase=\(interacting ? "gesture" : "idle") tracking=\(tracking) dragging=\(dragging)"
                + " decelerating=\(decelerating) swiftUI=\(swiftUI)"
                + " host=\(ObjectIdentifier(scrollView)) hosting=\(scrollState.momentumProxy.hostingRevision)"
                + " offset=\(scrollView.contentOffset.y) content=\(scrollView.contentSize.height) viewport=\(scrollView.bounds.height)"
                + " insets=\(scrollView.adjustedContentInset)"
                + " away=\(scrollState.userIsScrolledAway) pendingRestore=\(scrollState.hasPendingViewportRestoration)"
                + " visible=\(String(describing: scrollState.viewportAnchor.visiblePosition))"
                + " restoration=[\(scrollState.viewportAnchor.restorationSummary)]"
        }
        set { super.accessibilityValue = newValue }
    }
}
