import Foundation
import Testing
@testable import Intent

/// Tests for PersistenceManager per-workspace screen persistence.
/// Uses a unique key prefix per test to avoid UserDefaults collisions.
@Suite(.serialized)
struct PersistenceManagerTests {

    // MARK: - Setup / Teardown helper

    /// Clean up UserDefaults keys used by PersistenceManager for workspace screens.
    private func cleanup(workspaceIds: [String]) {
        for id in workspaceIds {
            PersistenceManager.shared.clearWorkspaceScreen(workspaceId: id)
        }
    }

    // MARK: - saveWorkspaceScreen / loadWorkspaceScreen round-trip

    @Test func roundTripConversationScreen() {
        let wsId = "test-ws-roundtrip-conv-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "agent-42", agentName: "Builder",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-42")
        #expect(loaded?.agentName == "Builder")
        #expect(loaded?.workspaceId == wsId)
    }

    @Test func roundTripNoteScreen() {
        let wsId = "test-ws-roundtrip-note-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: wsId,
            agentId: nil, agentName: nil,
            noteId: "note-123", noteTitle: "My Note"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded != nil)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "note-123")
        #expect(loaded?.noteTitle == "My Note")
    }

    // MARK: - Load returns nil for unknown workspace

    @Test func loadReturnsNilForUnknownWorkspace() {
        let loaded = PersistenceManager.shared.loadWorkspaceScreen(
            workspaceId: "nonexistent-ws-\(UUID().uuidString)"
        )
        #expect(loaded == nil)
    }

    // MARK: - clearWorkspaceScreen

    @Test func clearRemovesSavedScreen() {
        let wsId = "test-ws-clear-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "a", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: screen)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) != nil)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: wsId)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId) == nil)
    }

    // MARK: - Independent workspaces

    @Test func differentWorkspacesMaintainIndependentScreens() {
        let ws1 = "test-ws-indep-1-\(UUID().uuidString)"
        let ws2 = "test-ws-indep-2-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen1 = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: ws1,
            agentId: "agent-A", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        let screen2 = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: ws2,
            agentId: nil, agentName: nil,
            noteId: "note-B", noteTitle: "B"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen1)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen2)

        let loaded1 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1)
        let loaded2 = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2)
        #expect(loaded1?.screen == "conversation")
        #expect(loaded1?.agentId == "agent-A")
        #expect(loaded2?.screen == "note")
        #expect(loaded2?.noteId == "note-B")
    }

    @Test func clearOneWorkspaceDoesNotAffectOther() {
        let ws1 = "test-ws-clear-one-\(UUID().uuidString)"
        let ws2 = "test-ws-clear-other-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [ws1, ws2]) }

        let screen = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: ws1,
            agentId: "a", agentName: "A",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws1, screen: screen)
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: ws2, screen: screen)

        PersistenceManager.shared.clearWorkspaceScreen(workspaceId: ws1)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws1) == nil)
        #expect(PersistenceManager.shared.loadWorkspaceScreen(workspaceId: ws2) != nil)
    }

    // MARK: - Overwrite

    @Test func savingOverwritesPreviousScreen() {
        let wsId = "test-ws-overwrite-\(UUID().uuidString)"
        defer { cleanup(workspaceIds: [wsId]) }

        let first = PersistenceManager.SavedScreen(
            screen: "conversation", workspaceId: wsId,
            agentId: "a1", agentName: "First",
            noteId: nil, noteTitle: nil
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: first)

        let second = PersistenceManager.SavedScreen(
            screen: "note", workspaceId: wsId,
            agentId: nil, agentName: nil,
            noteId: "n2", noteTitle: "Second"
        )
        PersistenceManager.shared.saveWorkspaceScreen(workspaceId: wsId, screen: second)

        let loaded = PersistenceManager.shared.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "note")
        #expect(loaded?.noteId == "n2")
    }
}

