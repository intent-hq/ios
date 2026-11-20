import SwiftUI
import UIKit

struct EdgeDrawerGesture: ViewModifier {
    let side: EdgeDrawerSide
    let isEnabled: Bool
    let isOpen: Binding<Bool>
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(EdgeDrawerPan(
            side: side,
            isEnabled: isEnabled,
            isOpen: isOpen,
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        ))
        #else
        content
        #endif
    }
}

#if os(iOS)
private final class EdgeDrawerPanRecognizer: UIPanGestureRecognizer {}

private struct EdgeDrawerPan: UIGestureRecognizerRepresentable {
    let side: EdgeDrawerSide
    let isEnabled: Bool
    let isOpen: Binding<Bool>
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = EdgeDrawerPanRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        recognizer.isEnabled = isEnabled
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.isOpen = isOpen
        recognizer.isEnabled = isEnabled
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator {
        Coordinator(side: side, isOpen: isOpen)
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        let translation = EdgeDrawerDrag.towardOpening(recognizer.translation(in: recognizer.view).x, side: side)
        switch recognizer.state {
        case .began, .changed:
            onChanged(translation)
        case .ended:
            onEnded(translation, EdgeDrawerDrag.towardOpening(recognizer.velocity(in: recognizer.view).x, side: side))
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        let side: EdgeDrawerSide
        var isOpen: Binding<Bool>

        init(side: EdgeDrawerSide, isOpen: Binding<Bool>) {
            self.side = side
            self.isOpen = isOpen
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let width = pan.view?.bounds.width ?? 0
            let startX = pan.location(in: pan.view).x - pan.translation(in: pan.view).x
            let velocity = pan.velocity(in: pan.view)
            return EdgeDrawerDrag.canBegin(
                isOpen: isOpen.wrappedValue,
                startX: EdgeDrawerDrag.distanceFromEdge(startX, width: width, side: side),
                velocity: CGPoint(x: EdgeDrawerDrag.towardOpening(velocity.x, side: side), y: velocity.y)
            )
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            otherGestureRecognizer is UIPanGestureRecognizer && !(otherGestureRecognizer is EdgeDrawerPanRecognizer)
        }
    }
}
#endif
