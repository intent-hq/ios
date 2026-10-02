import SwiftUI
import UIKit

struct ConnectionSwitcherGesture: ViewModifier {
    let isEnabled: Bool
    let isOpen: Binding<Bool>
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(ConnectionSwitcherPan(
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
private struct ConnectionSwitcherPan: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let isOpen: Binding<Bool>
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat, CGFloat) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
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
        Coordinator(isOpen: isOpen)
    }

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
        // UIKit can ask before SwiftUI refreshes the representable; read the live state.
        var isOpen: Binding<Bool>

        init(isOpen: Binding<Bool>) { self.isOpen = isOpen }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let startX = pan.location(in: pan.view).x - pan.translation(in: pan.view).x
            return ConnectionSwitcherDrag.canBegin(isOpen: isOpen.wrappedValue, startX: startX, velocity: pan.velocity(in: pan.view))
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            // Row actions and scrolling wait for the direction/edge gate to reject this pan.
            otherGestureRecognizer is UIPanGestureRecognizer
        }
    }
}
#endif
