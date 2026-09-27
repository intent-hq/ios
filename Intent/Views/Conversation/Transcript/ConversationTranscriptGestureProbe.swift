import UIKit

/// Demo-only accessibility diagnostics, sampled when XCTest queries the value.
/// UIKit interaction flags are not Observation dependencies: caching them in a
/// SwiftUI body can leave an active report after deceleration has ended.
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
        }
        set { super.accessibilityValue = newValue }
    }
}
