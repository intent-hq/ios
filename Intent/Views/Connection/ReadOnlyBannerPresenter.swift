import SwiftUI
import UIKit

/// Hosts `ReadOnlyBanner` in a separate window of the SAME scene, like
/// `ConnectionLossPresenter`, so it stays above sheets and full-screen covers.
/// Unlike the blocking overlay it never snapshots, disables, or hides the app:
/// only touches on the banner itself are taken; all others pass through. The
/// window never becomes key, so a focused composer keeps its keyboard. While
/// shown, it adds the collapsed banner's height to the top safe area of the
/// source window's root controller and everything it presents, so navigation
/// bars, sheets and full-screen covers sit below the banner instead of under it.
struct ReadOnlyBannerPresenter: UIViewRepresentable {
    let isPresented: Bool
    let message: ReadOnlyBannerMessage
    let mismatches: [HostCertMismatch]
    let onHome: () -> Void
    var onRetry: (() -> Void)?

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
            onHome: coordinator.homeAction(onHome),
            onRetry: onRetry
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

        /// Stays non-key even when touched, so the app's first responder (a
        /// focused composer) and its keyboard are never taken away.
        override var canBecomeKey: Bool { false }

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
        /// Controllers carrying our extra top inset, with the value they had before.
        private var insetOwners: [ObjectIdentifier: InsetOwner] = [:]
        private var insetTimer: Timer?

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
                applyReservedInsets()
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
            applyReservedInsets()
            startInsetTimer()
            #if DEBUG
            DemoConnectionLoss.record("banner-presented")
            #endif
            UIAccessibility.post(notification: .announcement, argument: announcement)
        }

        /// Sheets and covers appear without any SwiftUI update to this view, so
        /// the presented chain is re-checked on a short timer while shown.
        private func startInsetTimer() {
            insetTimer?.invalidate()
            let timer = Timer(timeInterval: Self.insetRefreshInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.applyReservedInsets() }
            }
            RunLoop.main.add(timer, forMode: .common)
            insetTimer = timer
        }

        private static let insetRefreshInterval: TimeInterval = 0.1

        private func reservedHeight(for window: UIWindow) -> CGFloat {
            UIFontMetrics(forTextStyle: .subheadline)
                .scaledValue(for: ReadOnlyBannerMetrics.collapsedHeight, compatibleWith: window.traitCollection)
        }

        private func applyReservedInsets() {
            guard let sourceWindow, let root = sourceWindow.rootViewController else { return }
            let height = reservedHeight(for: sourceWindow)
            var controller: UIViewController? = root
            while let current = controller {
                if !(current is UIAlertController), !(current.presentationController is UIPopoverPresentationController) {
                    let previous = insetOwners[ObjectIdentifier(current)]?.previousTop ?? current.additionalSafeAreaInsets.top
                    insetOwners[ObjectIdentifier(current)] = InsetOwner(controller: current, previousTop: previous)
                    var insets = current.additionalSafeAreaInsets
                    if insets.top != previous + height {
                        insets.top = previous + height
                        current.additionalSafeAreaInsets = insets
                    }
                }
                controller = current.presentedViewController
            }
        }

        private func restoreReservedInsets() {
            insetTimer?.invalidate()
            insetTimer = nil
            for owner in insetOwners.values {
                guard let controller = owner.controller else { continue }
                var insets = controller.additionalSafeAreaInsets
                insets.top = owner.previousTop
                controller.additionalSafeAreaInsets = insets
            }
            insetOwners.removeAll()
        }

        private func hide() {
            restoreReservedInsets()
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

/// A controller carrying the banner's extra top inset, with the inset it had before.
private struct InsetOwner {
    weak var controller: UIViewController?
    let previousTop: CGFloat
}
