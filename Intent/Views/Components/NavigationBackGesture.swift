import SwiftUI

extension View {
    func intentNavigationBackButton() -> some View {
        modifier(IntentNavigationBackButtonModifier())
    }

    @ViewBuilder
    func nativeNavigationBackGesture() -> some View {
        #if os(iOS)
        background(NavigationBackGesture())
        #else
        self
        #endif
    }
}

private struct IntentNavigationBackButtonModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden()
            .nativeNavigationBackGesture()
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    IntentIconButton(icon: .arrowLeft, label: "Back") { dismiss() }
                }
                .intentToolbarSurface()
            }
    }
}

extension ToolbarContent {
    @ToolbarContentBuilder
    func intentToolbarSurface() -> some ToolbarContent {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if os(iOS)
private struct NavigationBackGesture: UIViewControllerRepresentable {
    func makeUIViewController(context _: Context) -> Controller { Controller() }

    func updateUIViewController(_: Controller, context _: Context) {}

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.restoreGesture()
    }

    final class Controller: UIViewController, UIGestureRecognizerDelegate {
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
            guard let navigationController,
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
