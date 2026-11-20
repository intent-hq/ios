import SwiftUI

extension View {
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
        guard let action else {
            settle()
            return
        }
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
    static let horizontalDominance: CGFloat = 1.5
    private static let resistance: CGFloat = 0.35
    private static let maximumOffset: CGFloat = 56
    static let horizontalScrollTolerance: CGFloat = 1

    static func resistedOffset(for translation: CGFloat) -> CGFloat {
        max(-maximumOffset, min(maximumOffset, translation * resistance))
    }

    static func outcome(translation: CGFloat, velocity: CGFloat) -> Outcome {
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

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            if otherGestureRecognizer is UIScreenEdgePanGestureRecognizer { return true }
            guard let view = gestureRecognizer.view, let otherView = otherGestureRecognizer.view,
                  otherView !== view, otherView.isDescendant(of: view) else { return false }
            if let scrollView = otherView as? UIScrollView, otherGestureRecognizer === scrollView.panGestureRecognizer {
                return Self.scrollsHorizontally(scrollView)
            }
            return otherGestureRecognizer is UIPanGestureRecognizer
        }

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
