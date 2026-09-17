import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test @MainActor func reconnect_missingAgent_bootsToWorkspaceDetail() async {
        let wsId = "test-coord-reconnect-gone-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "agent not found",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        // Seed the store so the reconnect overlay clears immediately.
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-gone", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"), "Reconnect must re-validate the open conversation's agent")
        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after reconnect with missing agent, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
            "Per-workspace saved sub-screen should be cleared for the missing agent"
        )
    }

    @Test @MainActor func reconnect_agentStillExists_staysOnConversation() async {
        let wsId = "test-coord-reconnect-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.responseMap["agent.get"] = ["agent": ["id": "agent-live"]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .agentConversation after reconnect, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_agentTransientError_staysOnConversation() async {
        let wsId = "test-coord-reconnect-transient-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Transient agent.get error must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_agentBare32602_staysOnConversation() async {
        let wsId = "test-coord-reconnect-bare32602-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // -32602 without data.code == "not-found" (invalid-params or a legacy
        // daemon omitting data) must NOT read as deletion (docs/PROTOCOL.md §9)
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"]
        )
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-live")
            #expect(wId == wsId)
        } else {
            Issue.record("A -32602 without data.code == \"not-found\" must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func reconnect_notOnConversation_doesNotValidateAgent() async {
        let wsId = "test-coord-reconnect-detail-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectWorkspace(wsId)
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(!fake.didCallMethod("agent.get"), "agent.get must not be called when not on a conversation screen")
        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after reconnect, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Missing agent handling (conversation fallback)

    @Test @MainActor func handleMissingAgent_navigatesToWorkspaceDetail_andClearsSavedScreen() {
        let wsId = "test-coord-missing-agent-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-gone", workspaceId: wsId, agentName: "Doomed")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.handleMissingAgent(agentId: "agent-gone", workspaceId: wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingAgent, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
            "Per-workspace saved sub-screen should be cleared for the missing agent"
        )
    }

    @Test @MainActor func handleMissingAgent_ignoredWhenNotOnConversationScreen() {
        // Self-initiated deletion dismisses the conversation first, so by the
        // time the agent:deleted fallback fires the screen is already
        // .workspaceDetail — the guard must make it a no-op (no double navigation).
        let wsId = "test-coord-missing-agent-noop-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        coordinator.handleMissingAgent(agentId: "agent-1", workspaceId: wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent off a conversation must not navigate, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingAgent_ignoredForDifferentWorkspace() {
        let wsId = "test-coord-missing-agent-otherws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        coordinator.handleMissingAgent(agentId: "agent-1", workspaceId: "some-other-workspace")

        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another workspace must not navigate, got \(coordinator.currentScreen)")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func handleMissingAgent_ignoredForDifferentAgent() {
        // A stale validation for agent A must not evict a live conversation
        // with agent B in the same workspace.
        let wsId = "test-coord-missing-agent-otheragent-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-b", workspaceId: wsId, agentName: "Alive")

        coordinator.handleMissingAgent(agentId: "agent-a", workspaceId: wsId)

        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another agent must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
            "The live conversation's saved sub-screen must not be cleared"
        )
    }

    // MARK: - Missing note handling

    @Test @MainActor func handleMissingNote_navigatesToWorkspaceDetail_andClearsSavedScreen() {
        let wsId = "test-coord-missing-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-gone", workspaceId: wsId, noteTitle: "Doomed Note")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil)

        coordinator.handleMissingNote(noteId: "note-gone", workspaceId: wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingNote, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
            "Per-workspace saved note screen should be cleared for the missing note"
        )
    }

    @Test @MainActor func handleMissingNote_ignoredWhenNotOnNoteScreen() {
        let wsId = "test-coord-missing-note-noop-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        coordinator.handleMissingNote(noteId: "note-1", workspaceId: wsId)

        if case let .agentConversation(agentId, wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote must not navigate away from a conversation, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingNote_ignoredForDifferentWorkspace() {
        let wsId = "test-coord-missing-note-otherws-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-1", workspaceId: wsId, noteTitle: "Note")

        coordinator.handleMissingNote(noteId: "note-1", workspaceId: "some-other-workspace")

        if case let .noteDetail(noteId, wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote for another workspace must not navigate, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func handleMissingNote_ignoredForDifferentNote() {
        // A stale validation for note A must not evict a live note B screen
        // in the same workspace (reachable via note-to-note links).
        let wsId = "test-coord-missing-note-othernote-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        coordinator.onSelectNote("note-b", workspaceId: wsId, noteTitle: "Alive Note")

        coordinator.handleMissingNote(noteId: "note-a", workspaceId: wsId)

        if case let .noteDetail(noteId, wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote for another note must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
            "The live note screen's saved sub-screen must not be cleared"
        )
    }

    // MARK: - Note validation on cold-start restore

    @Test @MainActor func restoreLastScreen_restoredNoteMissing_fallsBackToDetail() async {
        let wsId = "test-coord-restore-dead-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "note",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: "note-dead",
                noteTitle: "Dead Note"
            ),
            for: Self.windowBackend.connectionID
        )

        // No workspace publish: keep lastUpdated nil so the workspace-existence
        // validation stays inert and only the note validation path is exercised.
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // note.get answers -32602 with data.code == "not-found" for a
        // nonexistent note (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -32_602,
            userInfo: [
                NSLocalizedDescriptionKey: "note not found",
                NSError.intentErrorDataCodeKey: "not-found"
            ]
        )
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )

        coordinator.onConnectionSuccess()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"), "Restoring a note screen must re-validate the note")
        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after restoring a missing note, got \(coordinator.currentScreen)")
        }
        #expect(
            persistence.loadLastScreen(for: Self.windowBackend.connectionID)?.screen == "workspaceDetail",
            "The saved last screen should fall back to the workspace for the missing note"
        )
    }

    @Test @MainActor func restoreLastScreen_restoredNoteTransientError_staysOnNote() async {
        let wsId = "test-coord-restore-note-transient-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "note",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: "note-1",
                noteTitle: "Flaky Network Note"
            ),
            for: Self.windowBackend.connectionID
        )

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket",
            code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"]
        )
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )

        coordinator.onConnectionSuccess()
        await Self.drainMainQueue()

        if case let .noteDetail(noteId, wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-1")
            #expect(wId == wsId)
        } else {
            Issue.record("Transient note.get error must not navigate away, got \(coordinator.currentScreen)")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func restoreLastScreen_restoredNoteAlive_staysOnNote() async {
        let wsId = "test-coord-restore-note-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "note",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: "note-live",
                noteTitle: "Live Note"
            ),
            for: Self.windowBackend.connectionID
        )

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.responseMap["note.get"] = [
            "note": [
                "id": "note-live",
                "title": "Live Note",
                "content": "hello"
            ] as [String: Any]
        ] as [String: Any]
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            backendID: Self.windowBackend,
            persistence: persistence
        )

        coordinator.onConnectionSuccess()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"))
        if case let .noteDetail(noteId, wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .noteDetail for a live note, got \(coordinator.currentScreen)")
        }
    }
}
