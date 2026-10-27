import SwiftUI

extension View {
    /// A horizontal page swipe across a navigation pane: right goes back, left goes forward.
    /// Nested horizontal interactions (row swipe actions, sideways scrolling) keep priority.
    /// `isSwiping` stays true until a committed swipe finishes animating, so pages can slide.
    func paneSwipe(isSwiping: Binding<Bool>, onBack: (() -> Void)?, onForward: (() -> Void)?) -> some View {
        modifier(PaneSwipeGesture(isSwiping: isSwiping, onBack: onBack, onForward: onForward))
    }
}

private struct PaneSwipeGesture: ViewModifier {
    @Binding var isSwiping: Bool
    let onBack: (() -> Void)?
    let onForward: (() -> Void)?
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .offset(x: offset)
            .gesture(PanePan(
                allowsBack: onBack != nil,
                allowsForward: onForward != nil,
                onChanged: { translation in
                    isSwiping = true
                    offset = PaneSwipePolicy.resistedOffset(for: translation)
                },
                onEnded: finish,
                onCancelled: settle
            ))
        #else
        content
        #endif
    }

    private func finish(translation: CGFloat, velocity: CGFloat) {
        let action: (() -> Void)? = switch PaneSwipePolicy.outcome(translation: translation, velocity: velocity) {
        case .back: onBack
        case .forward: onForward
        case .none: nil
        }
        guard let action else { return settle() }
        withAnimation(PaneSwipePolicy.animation) {
            offset = 0
            action()
        } completion: {
            isSwiping = false
        }
    }

    private func settle() {
        withAnimation(PaneSwipePolicy.animation) {
            offset = 0
        } completion: {
            isSwiping = false
        }
    }
}

nonisolated enum PaneSwipePolicy {
    enum Outcome: Equatable {
        case back
        case forward
        case none
    }

    static let animationDuration: TimeInterval = 0.3
    static let animation = Animation.snappy(duration: animationDuration)
    static let commitDistance: CGFloat = 96
    static let commitVelocity: CGFloat = 640
    /// Horizontal speed must dominate vertical speed by this factor before the pane claims a drag.
    static let horizontalDominance: CGFloat = 1.5
    private static let resistance: CGFloat = 0.35
    private static let maximumOffset: CGFloat = 56
    /// Content wider than its viewport by more than rounding scrolls sideways.
    static let horizontalScrollTolerance: CGFloat = 1

    /// The pane only hints at the drag; the destination replaces it once committed.
    static func resistedOffset(for translation: CGFloat) -> CGFloat {
        max(-maximumOffset, min(maximumOffset, translation * resistance))
    }

    static func outcome(translation: CGFloat, velocity: CGFloat) -> Outcome {
        // A fast flick commits in its own direction; a slow drag needs distance and must not be reversing.
        if velocity >= commitVelocity || (translation >= commitDistance && velocity >= 0) { return .back }
        if velocity <= -commitVelocity || (translation <= -commitDistance && velocity <= 0) { return .forward }
        return .none
    }
}

#if os(iOS)
private struct PanePan: UIGestureRecognizerRepresentable {
    let allowsBack: Bool
    let allowsForward: Bool
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.allowsBack = allowsBack
        context.coordinator.allowsForward = allowsForward
        recognizer.isEnabled = allowsBack || allowsForward
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation(in: recognizer.view).x)
        case .ended:
            onEnded(recognizer.translation(in: recognizer.view).x, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsBack = false
        var allowsForward = false

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) * PaneSwipePolicy.horizontalDominance else { return false }
            return velocity.x > 0 ? allowsBack : allowsForward
        }

        /// Edge pops, row swipe actions and sideways-scrolling content inside the pane win.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // The navigation stack's interactive edge pop keeps its own edge.
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer { return true }
            guard let view = gestureRecognizer.view, let otherView = otherGestureRecognizer.view,
                  otherView !== view, otherView.isDescendant(of: view) else { return false }
            if let scrollView = otherView as? UIScrollView, otherGestureRecognizer === scrollView.panGestureRecognizer {
                return Self.scrollsHorizontally(scrollView)
            }
            return otherGestureRecognizer is UIPanGestureRecognizer
        }

        /// Vertical scrolling waits until a horizontal page swipe is ruled out.
        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView,
                  otherGestureRecognizer === scrollView.panGestureRecognizer else { return false }
            return !Self.scrollsHorizontally(scrollView)
        }

        private static func scrollsHorizontally(_ scrollView: UIScrollView) -> Bool {
            scrollView.contentSize.width > scrollView.bounds.width + PaneSwipePolicy.horizontalScrollTolerance
        }
    }
}
#endif
