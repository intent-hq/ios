import SwiftUI
import UIKit

/// A root overlay is below sheets and full-screen covers. A window in the SAME
/// scene covers those presentations without dismissing them or losing drafts.
/// Visibility is set synchronously, outside SwiftUI's transition machinery.
struct ConnectionLossPresenter: UIViewRepresentable {
    let isPresented: Bool
    var startupState: DaemonStartupState?
    var onRetry: (() -> Void)?
    let mismatches: [HostCertMismatch]
    var machineName: String?
    var reason: String?
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
            startupState: startupState,
            onRetry: onRetry,
            mismatches: mismatches,
            machineName: machineName,
            reason: reason,
            networkStatus: networkStatus,
            sourceColorScheme: context.environment.colorScheme,
            onHome: coordinator.homeAction(onHome)
        )
        coordinator.update(
            isPresented: isPresented,
            content: AnyView(content.environment(\.self, context.environment))
        )
        // An initial update can precede didMoveToWindow. Window membership
        // can also disappear temporarily; dismantle owns permanent teardown.
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

    enum HideReason: String {
        case sourceWindowChanged, detached, presentationEnded, explicit
    }

    @MainActor
    final class Coordinator {
        private static let backdropBlurRadius: CGFloat = 12
        private weak var sourceWindow: UIWindow?
        private var overlayWindow: UIWindow?
        private var host: UIHostingController<AnyView>?
        private var sourceSnapshot: UIImage?
        private var sourceAccessibilityHidden = false
        private var sourceInteractionEnabled = true
        private var isPresented = false
        private var content = AnyView(EmptyView())

        func attach(to window: UIWindow?) {
            // UIKit/SwiftUI may temporarily remove the anchor during scene
            // transitions. A missing window is not a request to dismiss an
            // existing loss or discard pending content. Keep the source until
            // a real rebind, recovery, Home, or dismantleUIView tears it down.
            guard let window else { return }
            guard sourceWindow !== window else { return }
            hide(reason: .sourceWindowChanged)
            sourceWindow = window
            refresh()
        }

        func detach() {
            hide(reason: .detached)
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
                hide(reason: .presentationEnded)
                return
            }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                UIView.performWithoutAnimation {
                    if let host {
                        host.rootView = presentedContent
                        return
                    }
                    sourceAccessibilityHidden = sourceWindow.accessibilityElementsHidden
                    sourceInteractionEnabled = sourceWindow.isUserInteractionEnabled
                    sourceWindow.endEditing(true)
                    // Freeze the actual page, including presented sheets, before
                    // showing our window. A material would add its own tint on
                    // top of the design's tint and flatten the frosted detail.
                    sourceSnapshot = snapshot(of: sourceWindow)
                    sourceWindow.accessibilityElementsHidden = true
                    sourceWindow.isUserInteractionEnabled = false

                    let host = UIHostingController(rootView: presentedContent)
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
                    #if DEBUG
                    DemoConnectionLoss.record("overlay-presented")
                    #endif
                    window.layoutIfNeeded()
                    UIAccessibility.post(notification: .screenChanged, argument: host.view)
                }
            }
        }

        private var presentedContent: AnyView {
            AnyView(content.background {
                if let sourceSnapshot {
                    Image(uiImage: sourceSnapshot)
                        .resizable()
                        .blur(radius: Self.backdropBlurRadius, opaque: true)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                } else {
                    Color(.connectionLossBackdrop).ignoresSafeArea()
                }
            })
        }

        private func snapshot(of window: UIWindow) -> UIImage? {
            guard !window.bounds.isEmpty else { return nil }
            // One point per pixel is sufficient for this diffuse backdrop. Keep this
            // transient image in memory only; hide releases it on every exit.
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
            var captured = false
            let image = renderer.image { _ in
                captured = window.drawHierarchy(in: window.bounds, afterScreenUpdates: false)
            }
            return captured ? image : nil
        }

        func hide(reason: HideReason = .explicit) {
            guard let overlayWindow else { return }
            UIView.performWithoutAnimation {
                let wasKey = overlayWindow.isKeyWindow
                overlayWindow.isHidden = true
                #if DEBUG
                DemoConnectionLoss.record("overlay-dismissed")
                DemoConnectionLoss.record("overlay-dismissed-\(reason.rawValue)")
                #endif
                host?.rootView = AnyView(EmptyView())
                overlayWindow.rootViewController = nil
                sourceWindow?.accessibilityElementsHidden = sourceAccessibilityHidden
                sourceWindow?.isUserInteractionEnabled = sourceInteractionEnabled
                if wasKey { sourceWindow?.makeKey() }
                self.overlayWindow = nil
                host = nil
                sourceSnapshot = nil
            }
            UIAccessibility.post(notification: .screenChanged, argument: nil)
        }
    }
}
