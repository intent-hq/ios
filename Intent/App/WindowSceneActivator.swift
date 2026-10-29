import SwiftUI
import UIKit

/// Brings this window's own scene forward. Raising by `openWindow(value:)`
/// is unreliable: a window switched to another backend in place keeps the
/// scene value it was created with, so raising by its current backend can
/// open a duplicate window instead.
@MainActor
final class WindowSceneActivator {
    weak var scene: UIWindowScene?
    private var activationState: () -> UIScene.ActivationState? = { nil }
    private var activate: () -> Void = {}

    init() {
        activationState = { [weak self] in self?.scene?.activationState }
        activate = { [weak self] in
            guard let session = self?.scene?.session else { return }
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: session))
        }
    }

    init(activationState: @escaping () -> UIScene.ActivationState?, activate: @escaping () -> Void) {
        self.activationState = activationState
        self.activate = activate
    }

    /// No-op for the window the user is already in, including a window that
    /// just switched backends in place to deliver this selection.
    func raiseIfNeeded() {
        guard let state = activationState(), state != .foregroundActive else { return }
        activate()
    }
}

/// Feeds the hosting scene to a `WindowSceneActivator`.
struct WindowSceneReader: UIViewRepresentable {
    let activator: WindowSceneActivator

    func makeUIView(context _: Context) -> ReaderView {
        let view = ReaderView()
        view.isUserInteractionEnabled = false
        view.activator = activator
        return view
    }

    func updateUIView(_ view: ReaderView, context _: Context) {
        view.activator = activator
    }

    final class ReaderView: UIView {
        weak var activator: WindowSceneActivator? {
            didSet { publishScene() }
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishScene()
        }

        private func publishScene() {
            guard let scene = window?.windowScene else { return }
            activator?.scene = scene
        }
    }
}

extension AppCoordinator {
    /// This window's agent-selection handler: bring the window forward where
    /// several windows exist, then navigate it to the selected agent.
    func agentSelectionHandler(
        raising activator: WindowSceneActivator?
    ) -> (String, String, String, UUID) -> Void {
        { [weak self] agentId, workspaceId, agentName, connectionId in
            activator?.raiseIfNeeded()
            self?.handleNotificationSelection(
                agentId: agentId,
                workspaceId: workspaceId,
                agentName: agentName,
                connectionId: connectionId
            )
        }
    }
}
