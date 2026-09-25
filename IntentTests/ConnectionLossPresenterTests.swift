@testable import Intent
import SwiftUI
import Testing
import UIKit

@MainActor
@Suite(.serialized)
struct ConnectionLossPresenterTests {
    private static let inheritedAnimationDuration: TimeInterval = 10
    private static let teardownTimeout: TimeInterval = 2

    @Test func showsAndHidesSynchronouslyInsideInheritedAnimation() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        source.rootViewController = UIViewController()
        source.makeKeyAndVisible()
        let presenter = ConnectionLossPresenter.Coordinator()
        defer {
            presenter.hide()
            source.isHidden = true
            previousKey?.makeKey()
        }
        presenter.attach(to: source)

        withAnimation(.linear(duration: Self.inheritedAnimationDuration)) {
            UIView.animate(withDuration: Self.inheritedAnimationDuration) {
                presenter.update(isPresented: true, content: AnyView(Text("Reconnecting")))
            }
        }
        let overlay = try #require(scene.windows.first { $0.windowLevel > .alert && !$0.isHidden })
        #expect(overlay.isKeyWindow)
        #expect(overlay.frame == source.frame)
        #expect(overlay.alpha == 1)
        #expect(overlay.layer.animationKeys()?.isEmpty != false)
        #expect(overlay.rootViewController?.view.accessibilityViewIsModal == true)
        #expect(source.accessibilityElementsHidden)
        #expect(!source.isUserInteractionEnabled)

        withAnimation(.linear(duration: Self.inheritedAnimationDuration)) {
            presenter.update(isPresented: false, content: AnyView(EmptyView()))
        }
        #expect(overlay.isHidden)
        #expect(overlay.rootViewController == nil)
        #expect(source.isKeyWindow)
        #expect(!source.accessibilityElementsHidden)
        #expect(source.isUserInteractionEnabled)
    }

    @Test func detachRestoresOriginalFlagsAndDoesNotTouchSiblingWindow() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        let sibling = UIWindow(windowScene: scene)
        let siblingAccessibilityHidden = sibling.accessibilityElementsHidden
        let siblingInteractionEnabled = sibling.isUserInteractionEnabled
        source.accessibilityElementsHidden = true
        source.isUserInteractionEnabled = false
        let presenter = ConnectionLossPresenter.Coordinator()
        defer {
            presenter.hide()
            source.isHidden = true
            previousKey?.makeKey()
        }
        presenter.attach(to: source)
        presenter.update(isPresented: true, content: AnyView(Text("Reconnecting")))
        #expect(sibling.accessibilityElementsHidden == siblingAccessibilityHidden)
        #expect(sibling.isUserInteractionEnabled == siblingInteractionEnabled)

        presenter.detach()
        #expect(source.accessibilityElementsHidden)
        #expect(!source.isUserInteractionEnabled)
        #expect(sibling.accessibilityElementsHidden == siblingAccessibilityHidden)
        #expect(sibling.isUserInteractionEnabled == siblingInteractionEnabled)
        source.isHidden = true
    }

    @Test(arguments: [false, true])
    func transientAnchorRemovalPreservesOverlayUntilExplicitDismissal(recoverWhileDetached: Bool) throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        source.rootViewController = UIViewController()
        source.makeKeyAndVisible()
        let presenter = ConnectionLossPresenter.Coordinator()
        let anchor = ConnectionLossPresenter.WindowAnchor()
        anchor.windowChanged = { [weak presenter] in presenter?.attach(to: $0) }
        defer {
            ConnectionLossPresenter.dismantleUIView(anchor, coordinator: presenter)
            source.isHidden = true
            previousKey?.makeKey()
        }
        source.rootViewController?.view.addSubview(anchor)
        presenter.update(isPresented: true, content: AnyView(Text("Reconnecting")))
        let overlay = try #require(scene.windows.first { $0.windowLevel > .alert && !$0.isHidden })
        let host = overlay.rootViewController

        // Window membership can disappear before SwiftUI dismantles the view.
        // Drive didMoveToWindow itself, not only the coordinator's update API.
        anchor.removeFromSuperview()
        #expect(anchor.window == nil)
        #expect(!overlay.isHidden)
        #expect(overlay.rootViewController === host)
        #expect(source.accessibilityElementsHidden)
        #expect(!source.isUserInteractionEnabled)
        presenter.update(isPresented: !recoverWhileDetached, content: AnyView(Text("No network connection")))
        source.rootViewController?.view.addSubview(anchor)
        #expect(overlay.isHidden == recoverWhileDetached)
        if !recoverWhileDetached {
            #expect(overlay.rootViewController === host, "Reattachment must reuse the already-presented host")
            #expect(source.accessibilityElementsHidden)
            #expect(!source.isUserInteractionEnabled)
        }

        ConnectionLossPresenter.dismantleUIView(anchor, coordinator: presenter)
        #expect(overlay.isHidden)
        #expect(overlay.rootViewController == nil)
        #expect(source.isKeyWindow)
        #expect(!source.accessibilityElementsHidden)
        #expect(source.isUserInteractionEnabled)
        #expect(!scene.windows.contains { $0.windowLevel > .alert && !$0.isHidden })
    }

    @Test(arguments: [false, true])
    func dismantleReleasesHomeCaptureAndCoordinator(isPresented: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        source.rootViewController = UIViewController()
        source.makeKeyAndVisible()
        defer {
            source.isHidden = true
            previousKey?.makeKey()
        }

        var presenter: ConnectionLossPresenter.Coordinator? = .init()
        weak var weakPresenter: ConnectionLossPresenter.Coordinator?
        weakPresenter = presenter
        weak var weakCapture: HomeCapture?
        try autoreleasepool {
            let coordinator = try #require(presenter)
            let capture = HomeCapture()
            weakCapture = capture
            coordinator.attach(to: source)
            coordinator.update(isPresented: isPresented, content: content(for: coordinator, capturing: capture))
            ConnectionLossPresenter.dismantleUIView(.init(), coordinator: coordinator)
        }
        #expect(source.isKeyWindow)
        #expect(source.isUserInteractionEnabled)
        #expect(!source.accessibilityElementsHidden)
        // The window closes synchronously, but SwiftUI releases its rendered
        // graph on a later run-loop turn. Keep the coordinator alive throughout.
        let deadline = Date().addingTimeInterval(Self.teardownTimeout)
        while weakCapture != nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(weakCapture == nil, "Dismantle must release Home even while SwiftUI still owns the coordinator")
        presenter = nil
        #expect(weakPresenter == nil)
    }

    @Test func detachReleasesPendingHomeCaptureWithoutAWindow() {
        let presenter = ConnectionLossPresenter.Coordinator()
        weak var weakCapture: HomeCapture?
        autoreleasepool {
            let capture = HomeCapture()
            weakCapture = capture
            presenter.update(isPresented: true, content: content(for: presenter, capturing: capture))
        }
        #expect(weakCapture != nil, "Keep the initial update until didMoveToWindow supplies its window")
        presenter.attach(to: nil)
        #expect(weakCapture != nil, "A temporary window gap must preserve the pending presentation")
        presenter.detach()
        #expect(weakCapture == nil, "Detaching must clear content even when no overlay window was created")
    }

    @Test(arguments: [false, true])
    func storedContentDoesNotOwnPresenterCoordinator(isPresented: Bool) {
        weak var weakPresenter: ConnectionLossPresenter.Coordinator?
        weak var weakCapture: HomeCapture?
        autoreleasepool {
            let presenter = ConnectionLossPresenter.Coordinator()
            let capture = HomeCapture()
            weakPresenter = presenter
            weakCapture = capture
            presenter.update(isPresented: isPresented, content: content(for: presenter, capturing: capture))
        }
        #expect(weakPresenter == nil)
        #expect(weakCapture == nil)
    }

    @Test func repeatedCyclesAndHomeRemainSynchronous() throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.keyWindow
        let source = UIWindow(windowScene: scene)
        source.rootViewController = UIViewController()
        source.makeKeyAndVisible()
        let presenter = ConnectionLossPresenter.Coordinator()
        defer {
            presenter.detach()
            source.isHidden = true
            previousKey?.makeKey()
        }
        var homeCalls = 0
        let home = presenter.homeAction {
            #expect(!scene.windows.contains { $0.windowLevel > .alert && !$0.isHidden })
            #expect(source.isKeyWindow)
            #expect(source.isUserInteractionEnabled)
            homeCalls += 1
        }
        let content = AnyView(ConnectionLossOverlay(mismatches: [], onHome: home))
        for _ in 0..<3 {
            presenter.update(isPresented: true, content: content)
            presenter.attach(to: source)
            let overlay = try #require(scene.windows.first { $0.windowLevel > .alert && !$0.isHidden })
            #expect(overlay.isKeyWindow)
            #expect(!source.isUserInteractionEnabled)
            presenter.update(isPresented: false, content: content)
            #expect(overlay.isHidden)
            #expect(overlay.rootViewController == nil)
            #expect(source.isKeyWindow)
        }
        presenter.update(isPresented: true, content: content)
        withAnimation(.linear(duration: Self.inheritedAnimationDuration), home)
        #expect(homeCalls == 1)
        presenter.attach(to: source)
        #expect(!scene.windows.contains { $0.windowLevel > .alert && !$0.isHidden })
    }

    private final class HomeCapture {
        var calls = 0
    }

    private func content(for presenter: ConnectionLossPresenter.Coordinator, capturing capture: HomeCapture) -> AnyView {
        AnyView(ConnectionLossOverlay(mismatches: [], onHome: presenter.homeAction { capture.calls += 1 }))
    }
}
