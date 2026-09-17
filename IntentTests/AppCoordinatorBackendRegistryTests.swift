import Foundation
@testable import Intent
import Observation
import Security
import Synchronization
import Testing
import UIKit

extension AppCoordinatorTests {
    @Test @MainActor func onReconnect_noSavedConnections_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onReconnect()

        #expect(
            !coordinator.pairingShowsSavedConnections,
            "No saved connections must leave the pairing surface in first-run mode"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Connection-failure saved-connection alternatives

    @Test func alternativeConnections_excludesActiveConnection() {
        let active = Self.makeConnection(port: 1)
        let other = Self.makeConnection(port: 2)

        let result = ConnectionFailureView.alternativeConnections(
            connections: [active, other],
            activeId: active.id
        )

        #expect(result.map(\.id) == [other.id])
    }

    @Test func alternativeConnections_sortsMostRecentlyUsedFirst() {
        let older = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.1"], port: 1, name: "a", pairedAt: Date()),
            token: "t1",
            lastConnectedAt: Date(timeIntervalSinceNow: -3600)
        )
        let newer = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.2"], port: 2, name: "b", pairedAt: Date()),
            token: "t2",
            lastConnectedAt: Date()
        )
        let never = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.3"], port: 3, name: "c", pairedAt: Date()),
            token: "t3"
        )

        let result = ConnectionFailureView.alternativeConnections(
            connections: [never, older, newer],
            activeId: nil
        )

        #expect(result.map(\.id) == [newer.id, older.id, never.id])
    }

    @Test @MainActor func onSwitchConnection_activatesTargetAndRoutesToConnecting() {
        resetConnectionState()
        defer {
            resetConnectionState()
            cleanupLastScreen()
        }

        let originalConnection = persistence.upsertConnection(Self.makeConnection(port: 1))
        let targetConnection = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: originalConnection.id)
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail",
                workspaceId: "ws-1",
                agentId: nil,
                agentName: nil,
                noteId: nil,
                noteTitle: nil
            ),
            for: targetConnection.id
        )

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace("ws-1")
        coordinator.onSwitchConnection(id: targetConnection.id)

        #expect(persistence.activeConnection()?.id == targetConnection.id)
        #expect(
            persistence.loadLastScreen(for: targetConnection.id) == nil,
            "The target backend's last-screen state must be cleared on switch"
        )
        #expect(
            coordinator.selectedWorkspaceId == nil,
            "selectedWorkspaceId must be reset on switch"
        )
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSwitchConnection_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        let target = persistence.upsertConnection(Self.makeConnection(port: 2))
        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSwitchConnection(id: target.id)

        #expect(
            WorkspaceStore.shared.workspaces.isEmpty,
            "Previous daemon's workspaces must be dropped on switch"
        )
        #expect(
            WorkspaceStore.shared.lastUpdated == nil,
            "lastUpdated must be reset so ConnectingView waits for the new daemon's data"
        )
    }

    @Test @MainActor func onLogOff_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()

        #expect(WorkspaceStore.shared.workspaces.isEmpty)
        #expect(WorkspaceStore.shared.lastUpdated == nil)
    }

    @Test @MainActor func onDeleteConnection_active_resetsWorkspaceStore() {
        resetConnectionState()
        defer {
            resetConnectionState()
            Self.resetWorkspaceStore()
        }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)
        Self.seedWorkspaceStore()

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onDeleteConnection(id: active.id)

        #expect(WorkspaceStore.shared.workspaces.isEmpty)
        #expect(WorkspaceStore.shared.lastUpdated == nil)
    }

    @Test @MainActor func onSwitchConnection_resetsPairingShowsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let target = persistence.upsertConnection(Self.makeConnection(port: 1))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onSwitchConnection(id: target.id)

        #expect(!coordinator.pairingShowsSavedConnections)
    }

    @Test @MainActor func onDeleteConnection_nonActive_keepsScreenAndActiveConnection() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onConnectionSuccess()
        coordinator.onDeleteConnection(id: other.id)

        #expect(persistence.loadConnections().map(\.id) == [active.id])
        #expect(persistence.activeConnection()?.id == active.id)
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList to be untouched, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_active_routesLikeLogOff_flagsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(backendID: BackendID(active.id), persistence: persistence)
        coordinator.onDeleteConnection(id: active.id)

        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(
            coordinator.pairingShowsSavedConnections,
            "Pairing surface should offer the remaining saved connections"
        )
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_lastActive_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let only = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: only.id)

        let coordinator = AppCoordinator(backendID: BackendID(only.id), persistence: persistence)
        coordinator.onDeleteConnection(id: only.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func onDeleteConnection_lastNonActive_clearsSavedConnectionsFlag() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Post-Log Off state: no active pointer, one saved connection remaining.
        let remaining = persistence.upsertConnection(Self.makeConnection(port: 1))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onDeleteConnection(id: remaining.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(
            !coordinator.pairingShowsSavedConnections,
            "Flag must clear once no saved connections remain"
        )
    }

    // MARK: - Backend removal marks pinned windows for auto-close (spec decision 2)

    /// Registry whose session factory must never run: these tests only assert
    /// removal marks, which never create or tear down sessions.
    @MainActor static func markOnlySessionRegistry() -> BackendSessionRegistry {
        BackendSessionRegistry { kind in
            fatalError("Removal marks must not build sessions (got \(String(describing: kind)))")
        }
    }

    @Test @MainActor func onDeleteConnection_marksBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(Self.makeConnection(port: 1))
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry
        )

        coordinator.onDeleteConnection(id: doomed.id)

        #expect(
            registry.isBackendRemoved(BackendID(doomed.id)),
            "Deleting a saved connection must auto-close its pinned windows"
        )
    }

    @Test @MainActor func onLogOff_marksActiveBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: active.id)
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            backendID: BackendID(active.id),
            persistence: persistence,
            sessionRegistry: registry
        )

        coordinator.onLogOff()

        #expect(
            registry.isBackendRemoved(BackendID(active.id)),
            "Log Off forgets the active connection; its pinned windows must close"
        )
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneMarksBackendRemovedInSessionRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"],
                    port: 4242,
                    name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0),
                    certFingerprint: "aa:bb"
                ),
                token: "tok"
            )
        )

        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone])
        )

        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.removedIds == [doomed.id])
        #expect(
            registry.isBackendRemoved(BackendID(doomed.id)),
            "A synced tombstone must auto-close the removed backend's pinned windows"
        )
    }

    @Test @MainActor func refreshSyncedBackends_mergeAddNeverMarksBackendsRemoved() {
        resetConnectionState()
        defer { resetConnectionState() }

        let registry = Self.markOnlySessionRegistry()
        let coordinator = AppCoordinator(
            persistence: persistence,
            sessionRegistry: registry,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload])
        )

        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.addedIds.count == 1)
        #expect(
            registry.removedBackendIDs.isEmpty,
            "A merge that only adds must not mark anything removed"
        )
    }

    @Test @MainActor func onSelectWorkspace_ignoresSavedConversationScreen() {
        let wsId = "test-coord-restore-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a per-workspace conversation screen
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation",
                workspaceId: wsId,
                agentId: "agent-x",
                agentName: "Tester",
                noteId: nil,
                noteTitle: nil
            )
        )

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId)?.agentId == "agent-x")
    }

    @Test @MainActor func onSelectWorkspace_ignoresSavedNoteScreen() {
        let wsId = "test-coord-restore-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note",
                workspaceId: wsId,
                agentId: nil,
                agentName: nil,
                noteId: "note-abc",
                noteTitle: "My Note"
            )
        )

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId)?.noteId == "note-abc")
    }

    @Test @MainActor func onSelectWorkspace_fallsBackToDetailWhenNoSavedScreen() {
        let wsId = "test-coord-no-saved-\(UUID().uuidString)"
        defer { cleanupLastScreen() }
        // Ensure no saved screen
        persistence.clearWorkspaceScreen(workspaceId: wsId)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        if case let .workspaceDetail(wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onBackToWorkspaceDetail_clearsSavedScreen() {
        let wsId = "test-coord-back-clears-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a screen and select the workspace
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation",
                workspaceId: wsId,
                agentId: "a",
                agentName: "A",
                noteId: nil,
                noteTitle: nil
            )
        )

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // Now go back to workspace detail
        coordinator.onBackToWorkspaceDetail()

        // The per-workspace screen should be cleared
        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackToWorkspaceDetail")
    }
}

extension AppCoordinatorTests {
    @Test @MainActor func onSelectAgent_savesPerWorkspaceScreen() {
        let wsId = "test-coord-agent-saves-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-99", workspaceId: wsId, agentName: "Worker")

        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded?.screen == "conversation")
        #expect(loaded?.agentId == "agent-99")
        #expect(loaded?.agentName == "Worker")
    }
}
