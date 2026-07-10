import SwiftUI
import UIKit

/// A UIPanGestureRecognizer subclass that only recognizes horizontal pans.
/// It fails for vertical pans, allowing child ScrollViews to scroll normally.
class HorizontalPanGestureRecognizer: UIPanGestureRecognizer {
    private var directionDetermined = false
    private(set) var isHorizontal = false

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        directionDetermined = false
        isHorizontal = false
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)

        guard !directionDetermined else { return }

        let vel = velocity(in: view)
        let absX = abs(vel.x)
        let absY = abs(vel.y)

        // Need significant movement to determine direction
        guard absX > 30 || absY > 30 else { return }

        directionDetermined = true
        if absX > absY * 1.2 {
            isHorizontal = true
        } else {
            isHorizontal = false
            state = .failed  // Fail for vertical — let ScrollView handle it
        }
    }

    override func reset() {
        super.reset()
        directionDetermined = false
        isHorizontal = false
    }
}

/// UIView that installs its gesture recognizer on the window for proper touch passthrough.
/// hitTest returns nil so all touches pass through to views below, but the gesture
/// recognizer still receives touches because it's attached to the window.
class GesturePassthroughView: UIView {
    var panGesture: HorizontalPanGestureRecognizer?
    private var gestureInstalledOnWindow = false

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let gesture = panGesture, let window = window, !gestureInstalledOnWindow else { return }
        // Move gesture from self to window so it receives all touches
        if gesture.view == self {
            removeGestureRecognizer(gesture)
        }
        window.addGestureRecognizer(gesture)
        gestureInstalledOnWindow = true
    }

    override func removeFromSuperview() {
        if let gesture = panGesture, gestureInstalledOnWindow {
            gesture.view?.removeGestureRecognizer(gesture)
            gestureInstalledOnWindow = false
        }
        super.removeFromSuperview()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        return nil  // All touches pass through to views below
    }
}

/// Transparent overlay that captures horizontal pan gestures before child ScrollViews can.
/// Touches pass through to views below (taps, text input, vertical scrolling all work).
struct DirectionalPanOverlay: UIViewRepresentable {
    @Binding var dragOffset: CGFloat
    @Binding var gestureDirection: GestureDirection?
    var onSwipeEnded: (CGFloat, CGFloat) -> Void  // (finalOffset, predictedEndX)

    func makeUIView(context: Context) -> GesturePassthroughView {
        let view = GesturePassthroughView()
        view.backgroundColor = .clear

        let panGesture = HorizontalPanGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handlePan(_:))
        )
        panGesture.delegate = context.coordinator
        panGesture.cancelsTouchesInView = false
        panGesture.delaysTouchesBegan = false
        panGesture.delaysTouchesEnded = false

        view.panGesture = panGesture
        view.addGestureRecognizer(panGesture)  // Will be moved to window in didMoveToWindow

        context.coordinator.overlayView = view

        return view
    }

    func updateUIView(_ uiView: GesturePassthroughView, context: Context) {
        context.coordinator.onSwipeEnded = onSwipeEnded
        context.coordinator.overlayView = uiView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(dragOffset: $dragOffset, gestureDirection: $gestureDirection, onSwipeEnded: onSwipeEnded)
    }

    class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @Binding var dragOffset: CGFloat
        @Binding var gestureDirection: GestureDirection?
        var onSwipeEnded: (CGFloat, CGFloat) -> Void
        weak var overlayView: GesturePassthroughView?

        init(dragOffset: Binding<CGFloat>, gestureDirection: Binding<GestureDirection?>, onSwipeEnded: @escaping (CGFloat, CGFloat) -> Void) {
            _dragOffset = dragOffset
            _gestureDirection = gestureDirection
            self.onSwipeEnded = onSwipeEnded
        }

        // Only receive touches that are within the overlay's bounds
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let overlayView = overlayView else { return false }
            let location = touch.location(in: overlayView)
            return overlayView.bounds.contains(location)
        }

        @objc func handlePan(_ gesture: UIPanGestureRecognizer) {
            // Use the overlay view for translation reference
            guard let overlayView = overlayView else { return }
            let translation = gesture.translation(in: overlayView)

            switch gesture.state {
            case .began:
                break  // Don't set direction yet — wait for direction determination
            case .changed:
                gestureDirection = .horizontal  // Only reaches here if gesture didn't fail
                dragOffset = translation.x
            case .ended, .cancelled:
                let velocity = gesture.velocity(in: overlayView).x
                let predictedEnd = velocity * 0.15 + translation.x
                onSwipeEnded(translation.x, predictedEnd)
                dragOffset = 0
                gestureDirection = nil
            default:
                break
            }
        }

        // Allow all gestures to work simultaneously — our failure/success handling
        // takes care of exclusion for horizontal vs vertical
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            return true
        }

        // Make ScrollView's pan gesture wait for our gesture to determine direction.
        // If we fail (vertical), ScrollView starts. If we succeed (horizontal), we handle it.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if otherGestureRecognizer is UIPanGestureRecognizer && !(otherGestureRecognizer is UIScreenEdgePanGestureRecognizer) {
                return true
            }
            return false
        }
    }
}

