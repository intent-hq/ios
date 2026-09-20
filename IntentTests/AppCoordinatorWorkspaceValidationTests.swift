import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    // MARK: - Missing workspace handling

    @Test @MainActor func handleMissingWorkspace_navigatesToWorkspaceList() {
        let wsId = "test-coord-missing-ws-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        // Simulate being on a workspace detail screen
        coordinator.onSelectWorkspace(wsId)
        if case .workspaceDetail = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }

        // Now handle the missing workspace
        coordinator.handleMissingWorkspace()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.selectedWorkspaceId == nil, "selectedWorkspaceId should be nil after handleMissingWorkspace")
    }

    @Test @MainActor func handleMissingWorkspace_clearsSavedScreenState() {
        let wsId = "test-coord-missing-clears-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: Self.windowBackend.connectionID
        )

        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        coordinator.handleMissingWorkspace()

        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
            "Last screen should be cleared"
        )
    }

    @Test @MainActor func handleMissingWorkspace_worksFromConversationScreen() {
        let wsId = "test-coord-missing-conv-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-x", workspaceId: wsId, agentName: "Tester")

        if case .agentConversation = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .agentConversation, got \(coordinator.currentScreen)")
        }

        coordinator.handleMissingWorkspace()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace from conversation, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - iPhone note navigation regression tests

    @Test @MainActor func testNoteNavigationFromWorkspace_staysInWorkspace() {
        let wsId = "test-coord-note-nav-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-1", workspaceId: wsId, noteTitle: "Regression Note")

        if case let .noteDetail(noteId, wId, title) = coordinator.currentScreen {
            #expect(noteId == "note-reg-1")
            #expect(wId == wsId)
            #expect(title == "Regression Note")
        } else {
            Issue.record("Expected .noteDetail, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should remain set after note navigation")
    }

    @Test @MainActor func testBackFromNote_goesToWorkspaceDetail_notWorkspaceList() {
        let wsId = "test-coord-back-note-detail-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-2", workspaceId: wsId, noteTitle: "Back Test Note")
        coordinator.onBackFromNote()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId, "Should return to the same workspace")
        } else {
            Issue.record("Expected .workspaceDetail after onBackFromNote, got \(coordinator.currentScreen)")
        }
        // Ensure we did NOT end up at workspaceList
        if case .workspaceList = coordinator.currentScreen {
            Issue.record("onBackFromNote should go to .workspaceDetail, NOT .workspaceList")
        }
    }

    @Test @MainActor func testNoteNavigationPreservesWorkspaceId() {
        let wsId = "test-coord-preserve-wsid-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should be set after onSelectWorkspace")

        coordinator.onSelectNote("note-reg-3", workspaceId: wsId, noteTitle: "Preserve WS Note")
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId must not become nil after onSelectNote (regression: SwiftUI popped the stack)")
    }

    // MARK: - iPad back button after agent auto-restore regression tests

    @Test @MainActor func shouldRepushConversation_falseWhenUserNavigatedBack() {
        // Regression: the deferred iPad re-push used to check only the agent id,
        // so it re-pushed the conversation even after the coordinator had already
        // navigated back to .workspaceDetail — leaving the conversation visible
        // with a dead "< Agents" button.
        let repush = RootView.shouldRepushConversation(
            currentScreen: .workspaceDetail(workspaceId: "ws-1"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1"
        )
        #expect(!repush, "Must not re-push the conversation when currentScreen is no longer .agentConversation")
    }

    @Test @MainActor func shouldRepushConversation_trueWhenStillOnSameConversation() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-1", workspaceId: "ws-1", agentName: "Worker"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1"
        )
        #expect(repush, "Should re-push when the same conversation is still the current screen")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenAgentChangedAgain() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-2"
        )
        #expect(!repush, "A stale re-push for a superseded agent must be dropped")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenCoordinatorMovedToAnotherAgent() {
        // Coordinator moved on to a different agent before the view state re-synced:
        // the screen match must reject the stale re-push even though the pending
        // and view-state agent ids still agree.
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1"
        )
        #expect(!repush, "Re-push must be dropped when the coordinator now shows a different conversation")
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func onBackToWorkspaceDetail_fromConversation_setsWorkspaceDetail() {
        let wsId = "test-coord-back-from-conv-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onBackToWorkspaceDetail_idempotentWhenAlreadyOnDetail() {
        let wsId = "test-coord-back-idempotent-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()
        // A second back tap while already on .workspaceDetail must stay on detail.
        coordinator.onBackToWorkspaceDetail()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after repeated onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Fetch-driven workspace validation (lastUpdated race)

    static func makeWorkspace(
        id: String,
        status: String? = nil,
        attention: String? = nil
    ) -> Workspace {
        Workspace(
            id: id,
            title: "WS \(id)",
            branch: nil,
            baseRef: nil,
            status: status,
            activity: nil,
            displayStatus: nil,
            attention: attention,
            lastActivity: nil,
            updatedAt: nil,
            repositoryOwner: nil,
            repositoryName: nil,
            prStatus: nil,
            prNumber: nil,
            diffSummaryTotalFiles: nil,
            taskStatsTotal: nil,
            taskStatsCompleted: nil,
            taskStatsInProgress: nil,
            agentSummaryCount: nil
        )
    }

    // MARK: - Screen predicates for bounded waits

    /// `waitUntil` / `expectNever` conditions need a `Bool`; these name the
    /// screen a main-queue-hopping sink or spawned validation task lands on
    /// (or must not leave) instead of sleeping a guessed drain delay.
    static func isWorkspaceList(_ screen: AppScreen) -> Bool {
        if case .workspaceList = screen { return true }
        return false
    }

    static func isWorkspaceDetail(_ screen: AppScreen, for workspaceId: String) -> Bool {
        if case let .workspaceDetail(wId) = screen { return wId == workspaceId }
        return false
    }

    static func isConversation(_ screen: AppScreen, agentId: String, workspaceId: String) -> Bool {
        if case let .agentConversation(aId, wId, _) = screen { return aId == agentId && wId == workspaceId }
        return false
    }

    static func isNoteDetail(_ screen: AppScreen, noteId: String, workspaceId: String) -> Bool {
        if case let .noteDetail(nId, wId, _) = screen { return nId == noteId && wId == workspaceId }
        return false
    }

    // MARK: - workspace.markSeen on open

    @Test @MainActor func onSelectWorkspace_callsMarkSeenAndClearsUnreadLocally() async throws {
        let wsId = "test-coord-markseen-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        try await fake.waitForRequests("workspace.markSeen")

        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(
            store.workspaces.first?.attention == "none",
            "Opening a workspace must optimistically clear the local unread flag"
        )
    }

    @Test @MainActor func onConnectionSuccess_restoreIntoWorkspaceMarksSeen() async throws {
        let wsId = "test-coord-restore-markseen-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        // Cold-start restore into a workspace counts as viewing it (mirrors
        // the FE, which marks seen whenever the workspace surface activates).
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: Self.windowBackend.connectionID
        )

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )

        coordinator.onConnectionSuccess()
        try await fake.waitForRequests("workspace.markSeen")

        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(
            store.workspaces.first?.attention == "none",
            "Restoring into a workspace must clear the local unread flag"
        )
        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_markSeenFailureIsIgnored() async throws {
        let wsId = "test-coord-markseen-fail-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        // Older daemon without the method — must not disturb navigation
        fake.errorMap["workspace.markSeen"] = NSError(
            domain: "WebSocket",
            code: -32_601,
            userInfo: [NSLocalizedDescriptionKey: "Method not found"]
        )
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        try await fake.waitForRequests("workspace.markSeen")

        try await expectNever("navigation change after a failed markSeen") {
            !Self.isWorkspaceDetail(coordinator.currentScreen, for: wsId)
        }
    }

    @Test @MainActor func firstFetch_missingWorkspace_bootsToWorkspaceList() async throws {
        let wsId = "test-coord-firstfetch-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: FakeConnectionManager(),
            backendID: Self.windowBackend,
            persistence: persistence
        )
        coordinator.onSelectWorkspace(wsId)

        // Regression: the very first post-launch fetch must trigger validation
        // (lastUpdated used to be assigned after workspaces, so the first publish was skipped).
        // An empty first response must still invalidate Observation through the
        // fetch marker even though the workspace array remains empty.
        store.publishFetchedWorkspaces([])
        try await waitUntil(".workspaceList after first fetch without the workspace") {
            Self.isWorkspaceList(coordinator.currentScreen)
        }

        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
            "Last screen should be cleared"
        )
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func preFetchEmptyPublish_doesNotBootUserOut() async throws {
        let wsId = "test-coord-prefetch-\(UUID().uuidString)"
        defer { cleanupLastScreen() }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        // A publish before any successful fetch (lastUpdated still nil) must be ignored.
        store.workspaces = []
        try await expectNever("navigation away on an empty pre-fetch publish") {
            !Self.isWorkspaceDetail(coordinator.currentScreen, for: wsId)
        }
    }
}
