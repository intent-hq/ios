import SwiftUI

struct ConversationDestinationView: View {
    struct Target: Equatable {
        let agentId: String
        let workspaceId: String
        let agentName: String
    }

    let fallback: Target?
    let session: BackendSession
    @Environment(AppCoordinator.self) private var coordinator

    private var target: Target? {
        if case let .agentConversation(agentId, workspaceId, agentName) = coordinator.currentScreen {
            return Target(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        }
        return fallback
    }

    var body: some View {
        if let target {
            ConversationView(
                agentId: target.agentId,
                workspaceId: target.workspaceId,
                agentName: target.agentName,
                session: session
            )
            .id(target.agentId)
        }
    }
}
