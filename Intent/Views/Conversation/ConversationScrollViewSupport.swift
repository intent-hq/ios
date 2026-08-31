import Combine
import SwiftUI
import UIKit

/// Stores a weak reference to the underlying UIScrollView so we can stop inertial scrolling.
class ScrollViewMomentumProxy: ObservableObject {
    weak var scrollView: UIScrollView?

    /// Kills any ongoing deceleration by setting contentOffset to its current value.
    func stopMomentum() {
        AppLog.ui.debug("[SCROLL] stopMomentum called, scrollView=\(scrollView != nil)")
        guard let scrollView else {
            AppLog.ui.warning("[SCROLL] WARNING: scrollView is nil, cannot stop momentum")
            return
        }
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        AppLog.ui.debug("[SCROLL] Momentum stopped at offset \(scrollView.contentOffset)")
    }
}

/// A zero-size UIView that walks up the view hierarchy to find the enclosing UIScrollView.
struct ScrollViewFinder: UIViewRepresentable {
    let proxy: ScrollViewMomentumProxy

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.frame = .zero
        DispatchQueue.main.async {
            if let scrollView = Self.findScrollView(from: view) {
                proxy.scrollView = scrollView
                Self.installKeyboardDismissTap(on: scrollView)
                AppLog.ui.debug("[SCROLL] Found UIScrollView: \(scrollView)")
            } else {
                AppLog.ui.warning("[SCROLL] WARNING: Could not find UIScrollView in hierarchy")
            }
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    /// Installed directly on the transcript scroll view so SwiftUI's hosting
    /// recognizer does not starve UIKit link-tap recognizers in message content.
    private final class KeyboardDismissTapGesture: UITapGestureRecognizer, UIGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            addTarget(self, action: #selector(handleTap))
            cancelsTouchesInView = false
            delegate = self
        }

        @objc private func handleTap() {
            UIApplication.shared.sendAction(
                #selector(UIResponder.resignFirstResponder),
                to: nil, from: nil, for: nil
            )
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    private static func installKeyboardDismissTap(on scrollView: UIScrollView) {
        let installed = scrollView.gestureRecognizers?.contains {
            $0 is KeyboardDismissTapGesture
        }
        guard installed != true else { return }
        scrollView.addGestureRecognizer(KeyboardDismissTapGesture())
    }

    private static func findScrollView(from view: UIView) -> UIScrollView? {
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