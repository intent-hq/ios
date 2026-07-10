import Foundation
import Testing
@testable import Intent

@Suite(.serialized)
struct AppCoordinatorTests {

    // MARK: - Helper to check AppScreen cases

    private static func assertScreen(_ screen: AppScreen, is expected: String, file: String = #file, line: Int = #line) {
        let description = String(describing: screen)
        #expect(description.contains(expected), "Expected \(expected), got \(screen)")
    }

    // MARK: - Navigation transitions

    @Test @MainActor func onConnectionSuccess_setsWorkspaceList() {
        let coordinator = AppCoordinator()
        coordinator.onConnectionSuccess()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onConnectionFailed_setsConnectionFailed() {
        let coordinator = AppCoordinator()
        coordinator.onConnectionFailed(error: "timeout")
        if case .connectionFailed(let error) = coordinator.currentScreen {
            #expect(error == "timeout")
        } else {
            Issue.record("Expected .connectionFailed, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onRetryConnection_setsConnecting() {
        let coordinator = AppCoordinator()
        coordinator.onRetryConnection()
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onPaired_setsConnecting() {
        let coordinator = AppCoordinator()
        coordinator.onPaired()
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onOpenSettings_setsSettings() {
        let coordinator = AppCoordinator()
        coordinator.onOpenSettings()
        if case .settings = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .settings, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_setsPairing() {
        let coordinator = AppCoordinator()
        coordinator.onLogOff()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSettingsBack_setsWorkspaceList() {
        let coordinator = AppCoordinator()
        coordinator.onSettingsBack()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_setsPairing() {
        let coordinator = AppCoordinator()
        coordinator.onReconnect()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func initialScreen_isLoading() {
        let coordinator = AppCoordinator()
        if case .loading = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected initial screen to be .loading, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Per-workspace navigation state restoration

    /// Clean up all PersistenceManager state that could leak between tests
    private static func cleanupLastScreen() {
        PersistenceManager.shared.clearLastScreen()
    }

    @Test @MainActor func onSelectWorkspace_restoresSavedConversationScreen() {
        let wsId = "test-coord-restore-conv-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        // Save a per-workspace conversation screen
        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-x", agentName: "Tester",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)

        if case .agentConversation(let agentId, let wId, let name) = coordinator.currentScreen {
            #expect(agentId == "agent-x")
            #expect(wId == wsId)
            #expect(name == "Tester")
        } else {
            Issue.record("Expected .agentConversation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_restoresSavedNoteScreen() {
        let wsId = "test-coord-restore-note-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-abc", noteTitle: "My Note"))

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)

        if case .noteDetail(let noteId, let wId, let title) = coordinator.currentScreen {
            #expect(noteId == "note-abc")
            #expect(wId == wsId)
            #expect(title == "My Note")
        } else {
            Issue.record("Expected .noteDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_fallsBackToDetailWhenNoSavedScreen() {
        let wsId = "test-coord-no-saved-\(UUID().uuidString)"
        defer { Self.cleanupLastScreen() }
        // Ensure no saved screen
        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onBackToWorkspaceDetail_clearsSavedScreen() {
        let wsId = "test-coord-back-clears-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        // Save a screen and select the workspace
        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "a", agentName: "A",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)
        // Now go back to workspace detail
        coordinator.onBackToWorkspaceDetail()

        // The per-workspace screen should be cleared
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackToWorkspaceDetail")
    }

    @Test @MainActor func onSelectAgent_savesPerWorkspaceScreen() {
        let wsId = "test-coord-agent-saves-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectAgent("agent-99", workspaceId: wsId, agentName: "Worker")

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-99")
        #expect(loaded?.agentName == "Worker")
    }

    @Test @MainActor func onSelectNote_savesPerWorkspaceScreen() {
        let wsId = "test-coord-note-saves-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectNote("note-55", workspaceId: wsId, noteTitle: "Design Doc")

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-55")
        #expect(loaded?.noteTitle == "Design Doc")
    }

    @Test @MainActor func onBackFromNote_clearsPerWorkspaceScreen() {
        let wsId = "test-coord-backfromnote-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        // First select the workspace so selectedWorkspaceId is set
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-1", workspaceId: wsId, noteTitle: "Note")
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.onBackFromNote()

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackFromNote")
    }

    // MARK: - Missing workspace handling

    @Test @MainActor func handleMissingWorkspace_navigatesToWorkspaceList() {
        let wsId = "test-coord-missing-ws-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        // Simulate being on a workspace detail screen
        coordinator.onSelectWorkspace(wsId)
        if case .workspaceDetail = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }

        // Now handle the missing workspace
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace, got \(coordinator.currentScreen)")
        }
        #expect(coordinator.selectedWorkspaceId == nil, "selectedWorkspaceId should be nil after handleMissingWorkspace")
    }

    @Test @MainActor func handleMissingWorkspace_clearsSavedScreenState() {
        let wsId = "test-coord-missing-clears-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        // Save both last screen and per-workspace screen
        PersistenceManager.shared.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))
        PersistenceManager.shared.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-1", agentName: "Worker",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator()
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        // Both should be cleared
        #expect(PersistenceManager.shared.loadLastScreen() == nil, "Last screen should be cleared")
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }

    @Test @MainActor func handleMissingWorkspace_worksFromConversationScreen() {
        let wsId = "test-coord-missing-conv-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectAgent("agent-x", workspaceId: wsId, agentName: "Tester")

        if case .agentConversation = coordinator.currentScreen {
            // good
        } else {
            Issue.record("Expected .agentConversation, got \(coordinator.currentScreen)")
        }

        coordinator.handleMissingWorkspace(workspaceId: wsId)

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after handleMissingWorkspace from conversation, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - iPhone note navigation regression tests

    @Test @MainActor func testNoteNavigationFromWorkspace_staysInWorkspace() {
        let wsId = "test-coord-note-nav-\(UUID().uuidString)"
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-1", workspaceId: wsId, noteTitle: "Regression Note")

        if case .noteDetail(let noteId, let wId, let title) = coordinator.currentScreen {
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
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-reg-2", workspaceId: wsId, noteTitle: "Back Test Note")
        coordinator.onBackFromNote()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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
        defer {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
            Self.cleanupLastScreen()
        }

        let coordinator = AppCoordinator()
        coordinator.onSelectWorkspace(wsId)
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should be set after onSelectWorkspace")

        coordinator.onSelectNote("note-reg-3", workspaceId: wsId, noteTitle: "Preserve WS Note")
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId must not become nil after onSelectNote (regression: SwiftUI popped the stack)")
    }
}

