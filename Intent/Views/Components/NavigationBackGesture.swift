import SwiftUI

extension View {
    func intentNavigationBackButton(
        _ isVisible: Bool = true, usesWorkspaceVerticalBar: Bool = false, showsBackground: Bool = true
    ) -> some View {
        modifier(IntentNavigationBackButtonModifier(
            isVisible: isVisible, usesWorkspaceVerticalBar: usesWorkspaceVerticalBar, showsBackground: showsBackground
        ))
    }

    @ViewBuilder
    func nativeNavigationBackGesture(isEnabled: Bool = true) -> some View {
        #if os(iOS)
        background(NavigationBackGesture(isEnabled: isEnabled))
        #else
        self
        #endif
    }
}

private struct IntentNavigationBackButtonModifier: ViewModifier {
    let isVisible: Bool
    let usesWorkspaceVerticalBar: Bool
    let showsBackground: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.workspaceUsesVerticalBar) private var usesVerticalBar

    func body(content: Content) -> some View {
        if usesWorkspaceVerticalBar, usesVerticalBar {
            content
                .navigationBarBackButtonHidden()
                .nativeNavigationBackGesture()
                .toolbar {
                    if isVisible {
                        WorkspaceVerticalNavigationToolbar(isEnabled: true, onBack: dismiss.callAsFunction) {
                            EmptyView()
                        }
                    }
                }
        } else {
            content
                .navigationBarBackButtonHidden()
                .nativeNavigationBackGesture()
                .toolbar {
                    if isVisible {
                        ToolbarItem(placement: .topBarLeading) {
                            IntentIconButton(icon: .arrowLeft, label: "Back", showsBackground: showsBackground) { dismiss() }
                        }
                        .intentToolbarSurface()
                    }
                }
        }
    }
}

/// One vertical group keeps Back above the screen's overflow menu, below system status chrome.
struct WorkspaceVerticalNavigationToolbar<Actions: View>: ToolbarContent {
    let isEnabled: Bool
    var showsBackButton = true
    var backLabel: LocalizedStringKey = "Back"
    var backIdentifier = "navigation.back"
    let onBack: () -> Void
    @ViewBuilder let actions: Actions

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *), isEnabled {
            ToolbarItem(placement: .topBarTrailing) {
                VStack(spacing: 0) {
                    if showsBackButton {
                        IntentIconButton(icon: .arrowLeft, label: backLabel, showsBackground: false, action: onBack)
                            .accessibilityIdentifier(backIdentifier)
                    }
                    actions
                }
            }
            .axisBehavior(.verticalPreferred)
            .sharedBackgroundVisibility(.hidden)
            .contentMarginsRemoved()
        }
        #else
        // Legacy ToolbarContentBuilder requires an expression even when the group has no items.
        ToolbarItemGroup(placement: .automatic) { EmptyView() }
        #endif
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
