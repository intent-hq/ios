#if DEBUG
import Foundation
import SwiftUI

extension DemoFixtures {
    static func reselectConversationIfRequested(coordinator: AppCoordinator) async {
        guard DemoMode.isEnabled,
              let trigger = triggerFile(
                from: ProcessInfo.processInfo.arguments,
                prefix: "--demo-conversation-reselection-trigger-file="
              ) else { return }
        do {
            try await wait(for: .triggerFile(trigger))
            try Task.checkCancellation()
        } catch { return }
        guard case let .agentConversation(agentId, workspaceId, agentName) = coordinator.currentScreen else { return }
        coordinator.onSelectAgent(agentId, workspaceId: workspaceId, agentName: agentName)
    }
}

#if DEBUG
/// Demo-only (`--demo-toast`): holds an agent-completion toast in the app's toast position for
/// UI evidence. The demo window has no backend, so the routed toast would never present there.
struct DemoToastOverlay: ViewModifier {
    private let toast = ToastInfo(
        agentId: "demo-agent-implementor",
        workspaceId: "demo-ws-dashboard",
        agentName: "Dashboard Implementor",
        workspaceName: "Add usage analytics dashboard",
        sourceBackendID: BackendID(UUID())
    )

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if DemoMode.isEnabled, ProcessInfo.processInfo.arguments.contains("--demo-toast") {
                ToastView(toast: toast, onTap: {}, onDismiss: {})
                    .padding(.top, Constants.Root.toastTopPadding)
            }
        }
    }
}
#endif
#endif
