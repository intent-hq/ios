import SwiftUI
import UIKit

/// A root overlay is below sheets and full-screen covers. A window in the SAME
/// scene covers those presentations without dismissing them or losing drafts.
/// Visibility is set synchronously, outside SwiftUI's transition machinery.
struct ConnectionLossPresenter: UIViewRepresentable {
    let isPresented: Bool
    let mismatches: [HostCertMismatch]
    var networkStatus: NetworkAvailability.Status = .unknown
    let onHome: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WindowAnchor {
        let view = WindowAnchor()
        view.isUserInteractionEnabled = false
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: WindowAnchor, context: Context) {
        #if DEBUG
        NetworkCopyDiagnostics.current?.record(.presenter(
            networkStatus, offline: ConnectionNetworkMessage(status: networkStatus).isUnavailable, presented: isPresented
        ))
        #endif
        let coordinator = context.coordinator
        let content = ConnectionLossOverlay(
            mismatches: mismatches, networkStatus: networkStatus, onHome: coordinator.homeAction(onHome)
        )
        coordinator.update(
            isPresented: isPresented,
            content: AnyView(content.environment(\.self, context.environment))
        )
        // An initial update can precede didMoveToWindow. Keep that pending
        // content; only an actual removal/dismantle is a detach.
        if let window = uiView.window { coordinator.attach(to: window) }
    }

    static func dismantleUIView(_ uiView: WindowAnchor, coordinator: Coordinator) {
        uiView.windowChanged = nil
        coordinator.detach()
    }

    final class WindowAnchor: UIView {
        var windowChanged: ((UIWindow?) -> Void)?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            windowChanged?(window)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var sourceWindow: UIWindow?
        private var overlayWindow: UIWindow?
        private var host: UIHostingController<AnyView>?
        private var sourceAccessibilityHidden = false
        private var sourceInteractionEnabled = true
        private var isPresented = false
        private var content = AnyView(EmptyView())

        func attach(to window: UIWindow?) {
            guard let window else {
                detach()
                return
            }
            guard sourceWindow !== window else { return }
            hide()
            sourceWindow = window
            refresh()
        }

        func detach() {
            hide()
            isPresented = false
            content = AnyView(EmptyView())
            sourceWindow = nil
        }

        func homeAction(_ onHome: @escaping () -> Void) -> () -> Void {
            { [weak self] in
                // SwiftUI owns this coordinator while mounted. The stored
                // content must not own it back, even before a window exists.
                self?.detach()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction, onHome)
            }
        }

        func update(isPresented: Bool, content: AnyView) {
            self.isPresented = isPresented
            self.content = isPresented ? content : AnyView(EmptyView())
            refresh()
        }

        private func refresh() {
            guard isPresented, let sourceWindow, let scene = sourceWindow.windowScene else {
                hide()
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                UIView.performWithoutAnimation {
                    if let host {
                        host.rootView = content
                        return
                    }
                    sourceAccessibilityHidden = sourceWindow.accessibilityElementsHidden
                    sourceInteractionEnabled = sourceWindow.isUserInteractionEnabled
                    sourceWindow.endEditing(true)
                    sourceWindow.accessibilityElementsHidden = true
                    sourceWindow.isUserInteractionEnabled = false

                    let host = UIHostingController(rootView: content)
                    host.view.backgroundColor = .clear
                    host.view.accessibilityViewIsModal = true
                    let window = UIWindow(windowScene: scene)
                    window.frame = sourceWindow.frame
                    window.backgroundColor = .clear
                    window.windowLevel = .alert + 1
                    window.rootViewController = host
                    self.host = host
                    overlayWindow = window
                    window.makeKeyAndVisible()
                    DemoConnectionLoss.record("overlay-presented")
                    window.layoutIfNeeded()
                    UIAccessibility.post(notification: .screenChanged, argument: host.view)
                }
            }
        }

        func hide() {
            guard let overlayWindow else { return }
            UIView.performWithoutAnimation {
                let wasKey = overlayWindow.isKeyWindow
                overlayWindow.isHidden = true
                DemoConnectionLoss.record("overlay-dismissed")
                host?.rootView = AnyView(EmptyView())
                overlayWindow.rootViewController = nil
                sourceWindow?.accessibilityElementsHidden = sourceAccessibilityHidden
                sourceWindow?.isUserInteractionEnabled = sourceInteractionEnabled
                if wasKey { sourceWindow?.makeKey() }
                self.overlayWindow = nil
                host = nil
            }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
