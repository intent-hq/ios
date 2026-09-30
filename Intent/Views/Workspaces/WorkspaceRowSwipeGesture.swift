import SwiftUI
import UIKit

struct WorkspaceRowSwipeGesture: ViewModifier {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void
    @GestureState private var fallbackTranslation: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(HorizontalPan(
            onChanged: onChanged,
            onEnded: onEnded,
            onCancelled: onCancelled
        ))
        #else
        content.simultaneousGesture(
            DragGesture(minimumDistance: BrowserAppearance.minimumDrag)
                .updating($fallbackTranslation) { value, translation, _ in
                    if abs(value.translation.width) > abs(value.translation.height) {
                        translation = value.translation.width
                    }
                }
                .onEnded { value in
                    guard abs(value.translation.width) > abs(value.translation.height) else { return }
                    onEnded(value.translation.width)
                }
        )
        .onChange(of: fallbackTranslation) { _, value in
            if value == 0 {
                onCancelled()
            } else {
                onChanged(value)
            }
        }
        #endif
    }
}

#if os(iOS)
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void
    let onCancelled: () -> Void

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.maximumNumberOfTouches = 1
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func makeCoordinator(converter _: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context _: Context) {
        switch recognizer.state {
        case .began, .changed:
            onChanged(recognizer.translation(in: nil).x)
        case .ended:
            onEnded(recognizer.translation(in: nil).x)
        case .cancelled, .failed:
            onCancelled()
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: nil)
            return abs(velocity.x) > abs(velocity.y)
        }

        func gestureRecognizer(
            _: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            guard let scrollView = otherGestureRecognizer.view as? UIScrollView else { return false }
            return otherGestureRecognizer === scrollView.panGestureRecognizer
        }
    }
}
#endif
