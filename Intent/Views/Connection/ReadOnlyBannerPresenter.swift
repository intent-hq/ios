import SwiftUI
import UIKit

/// Hosts `ReadOnlyBanner` in a separate window of the SAME scene, like
/// `ConnectionLossPresenter`, so it stays above sheets and full-screen covers.
/// Unlike the blocking overlay it never snapshots, disables, or hides the app:
/// only touches on the banner itself are taken; all others pass through. The
/// window never becomes key, so a focused composer keeps its keyboard.
struct ReadOnlyBannerPresenter: UIViewRepresentable {
    let isPresented: Bool
    let message: ReadOnlyBannerMessage
    let mismatches: [HostCertMismatch]
    let onHome: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ConnectionLossPresenter.WindowAnchor {
        let view = ConnectionLossPresenter.WindowAnchor()
        view.isUserInteractionEnabled = false
        view.windowChanged = { [weak coordinator = context.coordinator] window in
            coordinator?.attach(to: window)
        }
        return view
    }

    func updateUIView(_ uiView: ConnectionLossPresenter.WindowAnchor, context: Context) {
        let coordinator = context.coordinator
        let content = ReadOnlyBanner(
            message: message,
            mismatches: mismatches,
            onHome: coordinator.homeAction(onHome)
        ) { [weak coordinator] frame in coordinator?.interactiveFrame = frame }
        coordinator.update(
            isPresented: isPresented,
            announcement: message.title,
            content: AnyView(content.environment(\.self, context.environment))
        )
        if let window = uiView.window { coordinator.attach(to: window) }
    }

    static func dismantleUIView(_ uiView: ConnectionLossPresenter.WindowAnchor, coordinator: Coordinator) {
        uiView.windowChanged = nil
        coordinator.detach()
    }

    /// Takes touches only inside the banner's reported frame.
    final class PassthroughWindow: UIWindow {
        var interactiveFrame: () -> CGRect = { .null }

        override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
            interactiveFrame().contains(point) && super.point(inside: point, with: event)
        }
    }

    @MainActor
    final class Coordinator {
        private weak var sourceWindow: UIWindow?
        private var bannerWindow: PassthroughWindow?
        private var host: UIHostingController<AnyView>?
        private var isPresented = false
        private var content = AnyView(EmptyView())
        private var announcement = ""
        var interactiveFrame = CGRect.null

        func attach(to window: UIWindow?) {
            guard let window, sourceWindow !== window else { return }
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
                self?.detach()
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction, onHome)
            }
        }

        func update(isPresented: Bool, announcement: String, content: AnyView) {
            self.isPresented = isPresented
            self.announcement = announcement
            self.content = isPresented ? content : AnyView(EmptyView())
            refresh()
        }

        private func refresh() {
            guard isPresented, let sourceWindow, let scene = sourceWindow.windowScene else {
                hide()
                return
            }
            if let host {
                host.rootView = content
                return
            }
            let host = UIHostingController(rootView: content)
            host.view.backgroundColor = .clear
            let window = PassthroughWindow(windowScene: scene)
            window.interactiveFrame = { [weak self] in self?.interactiveFrame ?? .null }
            window.frame = sourceWindow.frame
            window.backgroundColor = .clear
            // Below the blocking overlay (alert + 1), above every presentation.
            window.windowLevel = .alert - 1
            window.rootViewController = host
            self.host = host
            bannerWindow = window
            window.isHidden = false
            #if DEBUG
            DemoConnectionLoss.record("banner-presented")
            #endif
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        private func hide() {
            guard let bannerWindow else { return }
            bannerWindow.isHidden = true
            bannerWindow.rootViewController = nil
            host?.rootView = AnyView(EmptyView())
            self.bannerWindow = nil
            host = nil
            interactiveFrame = .null
            #if DEBUG
            DemoConnectionLoss.record("banner-dismissed")
            #endif
        }
    }
}
