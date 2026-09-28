import SwiftUI
import UIKit

struct WorkspaceScriptSwipeGesture: ViewModifier {
    @Binding var translation: CGFloat
    @Binding var isRevealed: Bool
    @GestureState private var fallbackTranslation: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        content.gesture(HorizontalPan(
            onChanged: { translation = $0 },
            onEnded: finish
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
                    finish(value.translation.width)
                }
        )
        .onChange(of: fallbackTranslation) { _, value in translation = value }
        #endif
    }

    private func finish(_ distance: CGFloat) {
        if distance < -BrowserAppearance.revealThreshold {
            isRevealed = true
        } else if distance > BrowserAppearance.revealThreshold {
            isRevealed = false
        }
        translation = 0
    }
}

#if os(iOS)
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let onChanged: (CGFloat) -> Void
    let onEnded: (CGFloat) -> Void

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
            onChanged(0)
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
