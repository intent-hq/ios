import SwiftUI

extension View {
    @ViewBuilder
    func nativeNavigationBackGesture(isEnabled: Bool = true) -> some View {
        #if os(iOS)
        background(NavigationBackGesture(isEnabled: isEnabled))
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct NavigationBackGesture: UIViewControllerRepresentable {
    let isEnabled: Bool

    func makeUIViewController(context _: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.allowsNavigation = isEnabled
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.restoreGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
        var allowsNavigation = true
        private weak var gesture: UIGestureRecognizer?
        private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
        private var wasEnabled = false

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard let gesture = navigationController?.interactivePopGestureRecognizer,
                  gesture.delegate !== self else { return }
            (gesture.delegate as? Controller)?.restoreGesture()
            self.gesture = gesture
            previousDelegate = gesture.delegate
            wasEnabled = gesture.isEnabled
            gesture.delegate = self
            gesture.isEnabled = true
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            restoreGesture()
        }

        func gestureRecognizerShouldBegin(_: UIGestureRecognizer) -> Bool {
            guard allowsNavigation, let navigationController,
                  navigationController.viewControllers.count > 1,
                  navigationController.transitionCoordinator == nil,
                  navigationController.presentedViewController == nil else { return false }
            var destination: UIViewController = self
            while let parent = destination.parent, parent !== navigationController {
                destination = parent
            }
            return navigationController.topViewController === destination
        }

        func restoreGesture() {
            if let gesture, gesture.delegate === self {
                gesture.delegate = previousDelegate
                gesture.isEnabled = wasEnabled
            }
            gesture = nil
            previousDelegate = nil
        }
    }
}
#endif
