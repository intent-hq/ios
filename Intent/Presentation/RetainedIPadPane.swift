import SwiftUI
import UIKit

struct RetainedIPadPane<Content: View>: View {
    let isVisible: Bool
    var keepsCoveredContentVisible = false
    @ViewBuilder let content: Content
    @Environment(\.isIPadPaneVisible) private var parentVisible

    private var isInteractive: Bool { parentVisible && isVisible }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(isVisible && (parentVisible || keepsCoveredContentVisible) ? 1 : 0)
            .allowsHitTesting(isInteractive)
            .accessibilityElement(children: .contain)
            .accessibilityHidden(true, isEnabled: !isInteractive)
            .environment(\.isIPadPaneVisible, isInteractive)
            .transformPreference(WorkspaceActionMenuInputTop.self) { inputTop in
                if !isInteractive { inputTop = nil }
            }
    }
}

/// The resized pane owns its interaction and accessibility bounds. Native lists
/// and navigation containers otherwise report their enclosing window's frame.
struct IPadPaneBounds: ViewModifier {
    let identifier: String
    let isAccessible: Bool

    func body(content: Content) -> some View {
        content
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
            .contentShape([.interaction, .accessibility], Rectangle())
            .accessibilityHidden(true, isEnabled: !isAccessible)
    }
}

struct IPadNavigationVisibility: ViewModifier {
    var isEnabled = true
    @Environment(\.isIPadPaneVisible) private var isPaneVisible

    func body(content: Content) -> some View {
        content
            .accessibilityHidden(true, isEnabled: isEnabled && !isPaneVisible)
            .background {
                if isEnabled {
                    IPadNavigationVisibilityBridge(isInteractive: isPaneVisible)
                        .frame(width: 0, height: 0)
                }
            }
    }
}

struct IPadNavigationVisibilityBridge: UIViewControllerRepresentable {
    let isInteractive: Bool

    func makeUIViewController(context _: Context) -> Controller {
        let controller = Controller()
        controller.isInteractive = isInteractive
        return controller
    }

    func updateUIViewController(_ controller: Controller, context _: Context) {
        controller.isInteractive = isInteractive
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator _: Void) {
        controller.restoreVisibility()
    }

    final class Controller: UIViewController {
        var isInteractive = true {
            didSet { applyVisibility() }
        }
        private weak var navigationView: UIView?
        private var originalAccessibilityHidden = false
        private var originalInteractionEnabled = true

        override func loadView() {
            view = UIView()
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            if parent == nil { restoreVisibility() } else { applyVisibility() }
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            applyVisibility()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            applyVisibility()
        }

        private func applyVisibility() {
            guard let target = navigationController?.view else { return }
            if navigationView !== target {
                restoreVisibility()
                navigationView = target
                originalAccessibilityHidden = target.accessibilityElementsHidden
                originalInteractionEnabled = target.isUserInteractionEnabled
            }
            // NavigationStack's native children escape outer SwiftUI hiding.
            target.accessibilityElementsHidden = !isInteractive || originalAccessibilityHidden
            target.isUserInteractionEnabled = isInteractive && originalInteractionEnabled
        }

        func restoreVisibility() {
            navigationView?.accessibilityElementsHidden = originalAccessibilityHidden
            navigationView?.isUserInteractionEnabled = originalInteractionEnabled
            navigationView = nil
        }
    }
}
