import Foundation

extension ConversationViewModel {
    var supportsConversationGoal: Bool { connection.capabilities.supportsConversationGoal }

    var conversationGoal: String? { supportsConversationGoal ? store.goal : nil }

    func routesAsGoalCommand(_ text: String) -> Bool {
        supportsConversationGoal && ConversationGoal.isCommand(text)
    }

    @discardableResult
    func sendGoalCommand(_ content: String) async -> Bool {
        guard !hasPendingAttachments else {
            goalError = ConversationGoal.attachmentsError
            return false
        }
        guard pendingGoalCommand != content else { return false }
        pendingGoalCommand = content
        defer { if pendingGoalCommand == content { pendingGoalCommand = nil } }
        let textRevision = composerTextRevision
        do {
            _ = try await store.sendGoalCommand(agentId: agentId, workspaceId: workspaceId, content: content)
            if composerTextRevision == textRevision {
                messageText = ""
                persistence.clearDraft(workspaceId: workspaceId, agentId: agentId, backendID: backendID)
            }
            return true
        } catch {
            goalError = Self.goalFailureMessage(error)
            return false
        }
    }

    func saveGoal(_ text: String) async -> String? {
        let goal = ConversationGoal.normalized(text)
        if let goal, goal.count > ConversationGoal.maximumLength {
            return "The goal is too long. Keep it to \(ConversationGoal.maximumLength) characters or fewer."
        }
        do {
            _ = try await store.setGoal(agentId: agentId, workspaceId: workspaceId, goal: goal)
            return nil
        } catch {
            return Self.goalFailureMessage(error)
        }
    }

    func removeGoal() async {
        if let failure = await saveGoal("") { goalError = failure }
    }

    nonisolated static func goalFailureMessage(_ error: Error) -> String {
        let detail = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return detail.isEmpty ? "The goal was not changed. Try again." : "The goal was not changed. \(detail)"
    }
}
