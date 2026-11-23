import Foundation

extension ConversationStore {
    @discardableResult
    func sendGoalCommand(agentId: String, workspaceId: String, content: String) async throws -> GoalSendOutcome {
        let outcome = try await commands.sendGoalCommand(agentId: agentId, workspaceId: workspaceId, content: content)
        switch outcome {
        case let .command(result):
            applyGoal(result.goal, for: agentId)
        case .delivered(queued: false):
            await fetchAgentStreamingState(agentId: agentId, raiseOnly: true)
        case .delivered(queued: true):
            break
        }
        return outcome
    }

    func setGoal(agentId: String, workspaceId: String, goal: String?) async throws -> GoalCommandResult {
        let result = try await commands.setGoal(agentId: agentId, workspaceId: workspaceId, goal: goal)
        applyGoal(result.goal, for: agentId)
        return result
    }

    func applyGoal(_ value: String?, for agentId: String) {
        guard self.agentId == nil || self.agentId == agentId else { return }
        goalRevision &+= 1
        if goal != value { goal = value }
    }
}
