import Foundation

extension ConversationStore {
    func sendGoalCommand(agentId: String, workspaceId: String, content: String) async throws -> GoalCommandResult? {
        let result = try await commands.sendGoalCommand(agentId: agentId, workspaceId: workspaceId, content: content)
        if let result { applyGoal(result.goal, for: agentId) }
        return result
    }

    func setGoal(agentId: String, workspaceId: String, goal: String?) async throws -> GoalCommandResult {
        let result = try await commands.setGoal(agentId: agentId, workspaceId: workspaceId, goal: goal)
        applyGoal(result.goal, for: agentId)
        return result
    }

    private func applyGoal(_ value: String?, for agentId: String) {
        guard self.agentId == nil || self.agentId == agentId, goal != value else { return }
        goal = value
    }
}
