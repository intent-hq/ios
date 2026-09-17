import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func onSelectAgent_bumpsConversationRequestId_afterBackAndReselect() {
        let wsId = "test-coord-reselect-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        let initial = coordinator.conversationRequestId

        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        let afterFirst = coordinator.conversationRequestId
        #expect(afterFirst != initial, "Selecting an agent must issue a navigation request")

        coordinator.onBackToWorkspaceDetail()
        #expect(
            coordinator.conversationRequestId == afterFirst,
            "Going back is not a conversation request"
        )

        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        #expect(
            coordinator.conversationRequestId != afterFirst,
            "Re-selecting the same agent after going back must issue a new navigation request"
        )
        if case let .agentConversation(agentId, workspaceId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(workspaceId == wsId)
        } else {
            Issue.record("Expected .agentConversation after re-selecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectAgent_sameAgentWhileScreenUnchanged_stillBumpsConversationRequestId() {
        let wsId = "test-coord-reselect-stale-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        let before = coordinator.conversationRequestId
        let screenBefore = coordinator.currentScreenDescription

        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        #expect(
            coordinator.currentScreenDescription == screenBefore,
            "Same-target select leaves the screen value unchanged"
        )
        #expect(
            coordinator.conversationRequestId != before,
            "Same-target select must still be observable through the request id"
        )
    }
}
