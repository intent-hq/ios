import Foundation
@testable import Intent
import Testing

extension AppCoordinatorTests {
    @Test @MainActor func commitNavigationKeepsItsRepositoryAndClearsWhenLeavingTheWorkspace() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.usesIPadShell = true
        coordinator.onSelectWorkspace("workspace-1")
        let commit = WorkspaceCommit(hash: "abc123", message: "Change", author: "Sam", date: "", agentId: nil, isPushed: true)
        coordinator.onSelectWorkspaceCommit(commit, workspaceId: "workspace-1", gitRootId: "ios")
        #expect(coordinator.workspaceCommit?.gitRootId == "ios")
        #expect(coordinator.workspaceCommit?.workspaceId == "workspace-1")
        #expect(coordinator.workspaceCommit?.commit == commit)

        coordinator.onSelectWorkspace("workspace-2")
        #expect(coordinator.workspaceCommit == nil)
        coordinator.onSelectWorkspaceCommit(commit, workspaceId: "workspace-2", gitRootId: nil)
        coordinator.onSelectAgent("agent-2", workspaceId: "workspace-2", agentName: "Worker")
        #expect(coordinator.workspaceCommit == nil)
    }

    @Test @MainActor func onSelectAgent_bumpsConversationRequestId_afterBackAndReselect() {
        let wsId = "test-coord-reselect-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

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
        defer { cleanupLastScreen() }

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

    @Test @MainActor func needsConversationRepush_trueForNewRequestOnRegularWidth() {
        #expect(RootView.needsConversationRepush(
            agentChanged: false,
            isNewRequest: true,
            isRegularWidth: true
        ))
    }

    @Test @MainActor func needsConversationRepush_trueForAgentChangeOnRegularWidth() {
        #expect(RootView.needsConversationRepush(
            agentChanged: true,
            isNewRequest: false,
            isRegularWidth: true
        ))
    }

    @Test @MainActor func needsConversationRepush_falseWhenNothingChanged() {
        #expect(!RootView.needsConversationRepush(
            agentChanged: false,
            isNewRequest: false,
            isRegularWidth: true
        ))
    }

    @Test @MainActor func needsConversationRepush_falseOnCompactWidth() {
        #expect(!RootView.needsConversationRepush(
            agentChanged: true,
            isNewRequest: true,
            isRegularWidth: false
        ))
        #expect(!RootView.needsConversationRepush(
            agentChanged: false,
            isNewRequest: true,
            isRegularWidth: false
        ))
    }

    @Test @MainActor func changedAgentSelection_secondSyncTriggerDoesNotRepushBeforeDeferredTick() {
        let wsId = "test-coord-double-trigger-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-A", workspaceId: wsId, agentName: "A")
        var showingConversation = true
        var programmaticConversationDismiss = false
        var conversationAgentId = "agent-A"
        var handledRequestId = coordinator.conversationRequestId
        let screenBefore = coordinator.currentScreenDescription

        coordinator.onSelectAgent("agent-B", workspaceId: wsId, agentName: "B")
        #expect(coordinator.currentScreenDescription != screenBefore)
        #expect(coordinator.conversationRequestId != handledRequestId)

        let firstAgentChanged = conversationAgentId != "agent-B"
        let firstIsNewRequest = handledRequestId != coordinator.conversationRequestId
        handledRequestId = coordinator.conversationRequestId
        conversationAgentId = "agent-B"
        #expect(showingConversation)
        #expect(RootView.needsConversationRepush(
            agentChanged: firstAgentChanged,
            isNewRequest: firstIsNewRequest,
            isRegularWidth: true
        ))
        programmaticConversationDismiss = true
        showingConversation = false

        let secondAgentChanged = conversationAgentId != "agent-B"
        let secondIsNewRequest = handledRequestId != coordinator.conversationRequestId
        #expect(!secondAgentChanged)
        #expect(!secondIsNewRequest)
        #expect(!showingConversation)
        #expect(
            !RootView.canPushConversationNow(repushInFlight: programmaticConversationDismiss),
            "Second sync run must leave the tear-down in place"
        )

        programmaticConversationDismiss = false
        #expect(RootView.canPushConversationNow(repushInFlight: programmaticConversationDismiss))
    }

    @Test @MainActor func canPushConversationNow_trueWhenNoRepushInFlight() {
        #expect(RootView.canPushConversationNow(repushInFlight: false))
    }
}
