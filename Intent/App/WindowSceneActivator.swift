import SwiftUI
import UIKit

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

    func raiseIfNeeded() {
        guard let state = activationState(), state != .foregroundActive else { return }
        activate()
    }
}

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
