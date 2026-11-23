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
        guard pendingGoalCommand == nil else { return false }
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
        do {
            _ = try await store.setGoal(agentId: agentId, workspaceId: workspaceId, goal: ConversationGoal.normalized(text))
            return nil
        } catch {
            return Self.goalFailureMessage(error)
        }
    }

    func removeGoal() async {
        if let failure = await saveGoal("") { goalError = failure }
    }

    nonisolated static func goalFailureMessage(_ error: Error) -> String {
        ConversationGoal.failureMessage(for: error)
    }
}
