import Foundation

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
