import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @MainActor private func ownerCoordinator() -> AppCoordinator {
        let connection = FakeConnectionManager()
        connection.connectionState = .connected
        connection.currentPrincipal = InvitedSessionFixtures.principal("owner", role: .owner)
        return AppCoordinator(workspaceStore: WorkspaceStore(connectionManager: connection), connection: connection, persistence: persistence)
    }

    @Test @MainActor func assistantSwitchPreservesWorkspaceConversation() {
        let coordinator = ownerCoordinator()
        coordinator.onSelectAgent("workspace-agent", workspaceId: "workspace", agentName: "Coder")

        coordinator.onSelectAssistant()

        #expect(coordinator.selectedSection == .assistant)
        #expect(coordinator.selectedWorkspaceId == "workspace")
        if case let .agentConversation(agentId, workspaceId, _) = coordinator.currentScreen {
            #expect(agentId == "workspace-agent")
            #expect(workspaceId == "workspace")
        } else {
            Issue.record("Switching to Assistant discarded workspace navigation")
        }
        coordinator.selectedSection = .workspaces
        #expect(coordinator.selectedWorkspaceId == "workspace")
    }

    @Test @MainActor func globalAgentSelectionOpensAssistantInsteadOfHiddenWorkspace() {
        let coordinator = ownerCoordinator()
        coordinator.onSelectAgent("chief-agent", workspaceId: Workspace.chiefWorkspaceId, agentName: "Chief of Staff")
        #expect(coordinator.selectedSection == .assistant)
        #expect(coordinator.assistantAgentId == "chief-agent")
        #expect(coordinator.selectedWorkspaceId == nil)
        if case .workspaceList = coordinator.currentScreen {
            // The workspace tab remains available when there is no previous selection.
        } else {
            Issue.record("Expected a workspace list behind the Assistant tab")
        }
    }

    @Test @MainActor func workspaceAgentSelectionLeavesAssistant() {
        let coordinator = ownerCoordinator()
        coordinator.onSelectAssistant(agentId: "chief-agent")
        coordinator.onSelectAgent("coder", workspaceId: "workspace", agentName: "Coder")
        #expect(coordinator.selectedSection == .workspaces)
        #expect(coordinator.assistantAgentId == "chief-agent")
        #expect(coordinator.selectedWorkspaceId == "workspace")
    }

    @Test @MainActor func explicitWorkspaceSelectionLeavesAssistant() {
        let coordinator = ownerCoordinator()
        coordinator.onSelectAssistant()
        coordinator.onSelectWorkspace("workspace")
        #expect(coordinator.selectedSection == .workspaces)
        #expect(coordinator.selectedWorkspaceId == "workspace")
    }
}
