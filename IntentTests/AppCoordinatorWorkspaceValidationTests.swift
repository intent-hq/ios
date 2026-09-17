import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test @MainActor func onSelectNote_savesPerWorkspaceScreen() {
        let wsId = "test-coord-note-saves-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectNote("note-55", workspaceId: wsId, noteTitle: "Design Doc")

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-55")
        #expect(loaded?.noteTitle == "Design Doc")
    }

    @Test @MainActor func onBackFromNote_clearsPerWorkspaceScreen() {
        let wsId = "test-coord-backfromnote-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        // First select the workspace so selectedWorkspaceId is set
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-1", workspaceId: wsId, noteTitle: "Note")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.onBackFromNote()

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackFromNote")
    }

    // MARK: - Missing workspace handling

    @Test @MainActor func handleMissingWorkspace_navigatesToWorkspaceList() {
        let wsId = "test-coord-missing-ws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save both last screen and per-workspace screen
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
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation",
                workspaceId: wsId,
                agentId: "agent-1",
                agentName: "Worker",
                noteId: nil,
                noteTitle: nil
            )
        )

        let coordinator = AppCoordinator(backendID: Self.windowBackend, persistence: persistence)
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        // Both should be cleared
        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
            "Last screen should be cleared"
        )
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }

    @Test @MainActor func handleMissingWorkspace_worksFromConversationScreen() {
        let wsId = "test-coord-missing-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId should be set after onSelectWorkspace")

        coordinator.onSelectNote("note-reg-3", workspaceId: wsId, noteTitle: "Preserve WS Note")
        #expect(coordinator.selectedWorkspaceId == wsId, "selectedWorkspaceId must not become nil after onSelectNote (regression: SwiftUI popped the stack)")
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func onBackToWorkspaceDetail_fromConversation_setsWorkspaceDetail() {
        let wsId = "test-coord-back-from-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()
        // Simulate the desynced state: a second back tap while already on .workspaceDetail
        // (with a stale saved conversation screen) must stay on detail and keep it cleared.
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation",
                workspaceId: wsId,
                agentId: "agent-1",
                agentName: "Worker",
                noteId: nil,
                noteTitle: nil
            )
        )
        coordinator.onBackToWorkspaceDetail()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after repeated onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
            "Repeated onBackToWorkspaceDetail should still clear the per-workspace screen"
        )
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

    /// Let main-queue-hopping sinks and spawned validation tasks run.
    static func drainMainQueue() async {
        let drainDelayNanoseconds: UInt64 = 200_000_000
        try? await Task.sleep(nanoseconds: drainDelayNanoseconds)
    }

    // MARK: - workspace.markSeen on open

    @Test @MainActor func onSelectWorkspace_callsMarkSeenAndClearsUnreadLocally() async {
        let wsId = "test-coord-markseen-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("workspace.markSeen"))
        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(
            store.workspaces.first?.attention == "none",
            "Opening a workspace must optimistically clear the local unread flag"
        )
    }

    @Test @MainActor func onConnectionSuccess_restoreIntoWorkspaceMarksSeen() async {
        let wsId = "test-coord-restore-markseen-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("workspace.markSeen"))
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

    @Test @MainActor func onSelectWorkspace_markSeenFailureIsIgnored() async {
        let wsId = "test-coord-markseen-fail-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        await Self.drainMainQueue()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("markSeen failure must not affect navigation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_missingWorkspace_bootsToWorkspaceList() async {
        let wsId = "test-coord-firstfetch-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
        await Self.drainMainQueue()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList after first fetch without the workspace, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID) == nil,
            "Last screen should be cleared"
        )
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func preFetchEmptyPublish_doesNotBootUserOut() async {
        let wsId = "test-coord-prefetch-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        // A publish before any successful fetch (lastUpdated still nil) must be ignored.
        store.workspaces = []
        await Self.drainMainQueue()

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("An empty pre-fetch publish must not navigate away, got \(coordinator.currentScreen)")
        }
    }
}
