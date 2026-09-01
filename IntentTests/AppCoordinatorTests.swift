import Foundation
import Observation
import Security
import Synchronization
import Testing
@testable import Intent

@Suite(.serialized)
final class AppCoordinatorTests {

    /// Per-test isolated persistence. Swift Testing creates a fresh suite
    /// instance per test, so each test gets its own UserDefaults suite and
    /// in-memory keychain — persisted navigation state written by one test
    /// can never leak into another (intent-hq/monorepo#2677). The suite's
    /// persistent domain is removed again in deinit so runs don't accumulate
    /// UUID-named plists in the test host.
    private let persistence: PersistenceManager
    private let suiteName: String

    init() {
        // The coordinator under test uses the injected per-test persistence,
        // but non-injected globals (e.g. ConnectionManager.shared's route
        // refresh) can still reach PersistenceManager.shared — keep its
        // keychain in-memory so SecItem is never hit in headless CI.
        _ = TestKeychainStorage.installed
        suiteName = "AppCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        persistence = PersistenceManager(
            defaults: defaults, keychainStorage: InMemoryKeychainStorage())
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    // MARK: - Navigation transitions

    @Test @MainActor func onConnectionSuccess_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionSuccess()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onConnectionFailed_setsConnectionFailed() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onConnectionFailed(error: "timeout")
        if case .connectionFailed(let error) = coordinator.currentScreen {
            #expect(error == "timeout")
        } else {
            Issue.record("Expected .connectionFailed, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onRetryConnection_setsConnecting() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onRetryConnection()
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onPaired_setsConnecting() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onPaired()
        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onOpenSettings_setsSettings() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onOpenSettings()
        if case .settings = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .settings, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_setsPairing() {
        resetConnectionState()
        defer { resetConnectionState() }
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSettingsBack_setsWorkspaceList() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSettingsBack()
        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_setsPairing() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func initialScreen_isLoading() {
        let coordinator = AppCoordinator(persistence: persistence)
        if case .loading = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected initial screen to be .loading, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func currentScreenInvalidatesObservation() {
        let coordinator = AppCoordinator(persistence: persistence)
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = coordinator.currentScreen
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        coordinator.onConnectionSuccess()

        #expect(changeCount.withLock { $0 } == 1)
    }

    // MARK: - Per-workspace navigation state restoration

    /// Clean up all PersistenceManager state that could leak between tests
    private func cleanupLastScreen() {
        persistence.clearLastScreen()
    }

    // MARK: - Connection routing

    /// Remove all connection-related state (new blob, legacy entries, active pointer).
    private func resetConnectionState() {
        let pm = persistence
        pm.deleteFromKeychain(account: pm.keychainAccountConnections)
        pm.deleteFromKeychain(account: pm.keychainAccountServer)
        pm.deleteFromKeychain(account: pm.keychainAccountToken)
        pm.defaults.removeObject(forKey: pm.activeConnectionIdKey)
        pm.defaults.removeObject(forKey: pm.serverKey)
    }

    private static func makeConnection(port: Int) -> StoredConnection {
        StoredConnection(
            server: PairedServer(
                hosts: ["10.0.0.1"], port: port, name: "daemon-\(port)", pairedAt: Date()),
            token: "tok-\(port)")
    }

    private static func makeWorkspace(id: String) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil, status: nil,
            activity: nil, displayStatus: nil, lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil, prNumber: nil,
            diffSummaryTotalFiles: nil, taskStatsTotal: nil, taskStatsCompleted: nil,
            taskStatsInProgress: nil, agentSummaryCount: nil, agentSummaryAgents: nil)
    }

    /// Seed WorkspaceStore.shared as if a previous daemon's list had loaded.
    @MainActor private static func seedWorkspaceStore() {
        WorkspaceStore.shared.workspaces = [makeWorkspace(id: "stale-ws")]
        WorkspaceStore.shared.lastUpdated = Date()
    }

    @MainActor private static func resetWorkspaceStore() {
        WorkspaceStore.shared.workspaces = []
        WorkspaceStore.shared.lastUpdated = nil
    }

    @Test @MainActor func onLoadComplete_routesToConnectingWhenActiveConnectionExists() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        persistence.setActiveConnection(id: stored.id)

        // Empty fake registry: onLoadComplete merges the synced registry, and
        // the default one would read the host machine's real keychain.
        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        if case .connecting = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .connecting, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLoadComplete_routesToPairingWhenNoActiveConnection() {
        resetConnectionState()
        defer { resetConnectionState() }

        // A saved connection without an active pointer must not auto-connect.
        persistence.upsertConnection(Self.makeConnection(port: 4242))

        let coordinator = AppCoordinator(
            persistence: persistence, syncedRegistry: Self.syncedRegistry(payloads: []))
        coordinator.onLoadComplete()

        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_forgetsActiveConnectionOnly_flagsSavedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(Self.makeConnection(port: 1))
        let other = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: active.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()

        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer the remaining saved connections")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onLogOff_lastConnection_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let only = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: only.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onLogOff()

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onPaired_resetsPairingShowsSavedConnections() {
        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onPaired()
        #expect(!coordinator.pairingShowsSavedConnections)
    }

    // MARK: - Synced backend registry merge

    /// Registry whose keychain returns the given records as raw rows.
    private static func syncedRegistry(payloads: [String]) -> SyncedBackendRegistry {
        let rows: [[String: Any]] = payloads.enumerated().map { index, payload in
            [
                kSecAttrAccount as String: "row-\(index)",
                kSecValueData as String: Data(payload.utf8),
            ]
        }
        return SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .rows(rows)),
            accessGroup: "T.dev.intentapp.backends")
    }

    private static let syncedLivePayload = #"{"v": 1, "label": "Synced Mac", "#
        + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
        + #""token": "tok-sync", "updatedAt": 100}"#

    @Test @MainActor func onLoadComplete_mergesRegistryAndOffersSyncedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.onLoadComplete()

        let loaded = persistence.loadConnections()
        #expect(loaded.map(\.token) == ["tok-sync"])
        #expect(coordinator.pairingShowsSavedConnections,
                "A merged synced connection must be offered on the pairing surface")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onScenePhaseActive_mergesRegistry() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.onScenePhaseActive()

        #expect(persistence.loadConnections().count == 1)
    }

    @Test @MainActor func refreshSyncedBackends_onPairingScreen_offersFreshlyMergedConnections() {
        resetConnectionState()
        defer { resetConnectionState() }

        // First-run pairing screen, empty registry: nothing offered.
        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [Self.syncedLivePayload]))
        coordinator.currentScreen = .pairing
        #expect(!coordinator.pairingShowsSavedConnections)

        // A foreground merge that adds a synced connection while the pairing
        // surface is up must start offering it.
        coordinator.onScenePhaseActive()
        #expect(coordinator.pairingShowsSavedConnections,
                "A merged synced connection must be offered on the already-visible pairing surface")
    }

    @Test @MainActor func refreshSyncedBackends_unavailableRegistryIsANoOp() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 4242))
        let registry = SyncedBackendRegistry(
            keychain: FakeSyncedKeychain(outcome: .failure(errSecNotAvailable)),
            accessGroup: "T.dev.intentapp.backends")
        let coordinator = AppCoordinator(persistence: persistence, syncedRegistry: registry)

        #expect(coordinator.refreshSyncedBackends() == nil)
        #expect(persistence.loadConnections().map(\.id) == [stored.id])
    }

    @Test @MainActor func refreshSyncedBackends_tombstoneOnActiveRoutesToPairing() {
        resetConnectionState()
        defer { resetConnectionState() }

        let doomed = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok"))
        let other = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: doomed.id)

        // Registry reads use the wall clock, so the tombstone must be recent
        // enough to be within the 30-day TTL and newer than the local pairing.
        let clock = Date().timeIntervalSince1970 * 1000
        let tombstone = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.9", "port": 4242, "fingerprint": "aa:bb", "#
            + #""updatedAt": \#(clock), "deleted": true}"#
        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [tombstone]))
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.removedActiveConnection == true)
        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(coordinator.pairingShowsSavedConnections,
                "The remaining saved connection must be offered on the pairing surface")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func refreshSyncedBackends_activeUpdateAdoptsCredentialsIntoConnectionManager() {
        resetConnectionState()
        defer { resetConnectionState() }

        let active = persistence.upsertConnection(
            StoredConnection(
                server: PairedServer(
                    hosts: ["10.9.9.9"], port: 4242, name: "daemon",
                    pairedAt: Date(timeIntervalSince1970: 0), certFingerprint: "aa:bb"),
                token: "tok-old", syncUpdatedAt: 100))
        persistence.setActiveConnection(id: active.id)

        let rotated = #"{"v": 1, "label": "Synced Mac", "#
            + #""host": "10.9.9.10", "port": 5252, "fingerprint": "aa:bb", "#
            + #""token": "tok-rotated", "updatedAt": 200}"#
        let coordinator = AppCoordinator(
            persistence: persistence,
            syncedRegistry: Self.syncedRegistry(payloads: [rotated]))
        let outcome = coordinator.refreshSyncedBackends()

        #expect(outcome?.updatedIds == [active.id])
        let manager = ConnectionManager.shared
        #expect(manager.token == "tok-rotated")
        #expect(manager.port == 5252)
        #expect(manager.hosts.first == "10.9.9.10")
        #expect(manager.certFingerprint == "aa:bb")
    }

    @Test @MainActor func onReconnect_flagsSavedConnections_whenConnectionsExist() {
        resetConnectionState()
        defer { resetConnectionState() }

        let stored = persistence.upsertConnection(Self.makeConnection(port: 1))
        persistence.setActiveConnection(id: stored.id)

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onReconnect()

        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer saved connections after a startup connection failure")
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onReconnect_noSavedConnections_behavesLikeFirstRun() {
        resetConnectionState()
        defer { resetConnectionState() }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onReconnect()

        #expect(!coordinator.pairingShowsSavedConnections,
                "No saved connections must leave the pairing surface in first-run mode")
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
            connections: [active, other], activeId: active.id)

        #expect(result.map(\.id) == [other.id])
    }

    @Test func alternativeConnections_sortsMostRecentlyUsedFirst() {
        let older = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.1"], port: 1, name: "a", pairedAt: Date()),
            token: "t1", lastConnectedAt: Date(timeIntervalSinceNow: -3600))
        let newer = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.2"], port: 2, name: "b", pairedAt: Date()),
            token: "t2", lastConnectedAt: Date())
        let never = StoredConnection(
            server: PairedServer(hosts: ["10.0.0.3"], port: 3, name: "c", pairedAt: Date()),
            token: "t3")

        let result = ConnectionFailureView.alternativeConnections(
            connections: [never, older, newer], activeId: nil)

        #expect(result.map(\.id) == [newer.id, older.id, never.id])
    }

    @Test @MainActor func onSwitchConnection_activatesTargetAndRoutesToConnecting() {
        resetConnectionState()
        defer {
            resetConnectionState()
            cleanupLastScreen()
        }

        let a = persistence.upsertConnection(Self.makeConnection(port: 1))
        let b = persistence.upsertConnection(Self.makeConnection(port: 2))
        persistence.setActiveConnection(id: a.id)
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: "ws-1",
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace("ws-1")
        coordinator.onSwitchConnection(id: b.id)

        #expect(persistence.activeConnection()?.id == b.id)
        #expect(persistence.loadLastScreen() == nil,
                "Last-screen state must be cleared on switch")
        #expect(coordinator.selectedWorkspaceId == nil,
                "selectedWorkspaceId must be reset on switch")
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

        #expect(WorkspaceStore.shared.workspaces.isEmpty,
                "Previous daemon's workspaces must be dropped on switch")
        #expect(WorkspaceStore.shared.lastUpdated == nil,
                "lastUpdated must be reset so ConnectingView waits for the new daemon's data")
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

        let coordinator = AppCoordinator(persistence: persistence)
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

        let coordinator = AppCoordinator(persistence: persistence)
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

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onDeleteConnection(id: active.id)

        #expect(persistence.loadConnections().map(\.id) == [other.id])
        #expect(persistence.activeConnection() == nil)
        #expect(coordinator.pairingShowsSavedConnections,
                "Pairing surface should offer the remaining saved connections")
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

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onDeleteConnection(id: only.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections)
        if case .pairing = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .pairing, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onDeleteConnection_lastNonActive_clearsSavedConnectionsFlag() {
        resetConnectionState()
        defer { resetConnectionState() }

        // Post-Log Off state: no active pointer, one saved connection remaining.
        let remaining = persistence.upsertConnection(Self.makeConnection(port: 1))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.pairingShowsSavedConnections = true
        coordinator.onDeleteConnection(id: remaining.id)

        #expect(persistence.loadConnections().isEmpty)
        #expect(!coordinator.pairingShowsSavedConnections,
                "Flag must clear once no saved connections remain")
    }

    @Test @MainActor func onSelectWorkspace_restoresSavedConversationScreen() {
        let wsId = "test-coord-restore-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a per-workspace conversation screen
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-x", agentName: "Tester",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-abc", noteTitle: "My Note"))

        let coordinator = AppCoordinator(persistence: persistence)
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
        defer { cleanupLastScreen() }
        // Ensure no saved screen
        persistence.clearWorkspaceScreen(workspaceId: wsId)

        let coordinator = AppCoordinator(persistence: persistence)
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        // Save a screen and select the workspace
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "a", agentName: "A",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectWorkspace(wsId)
        // Now go back to workspace detail
        coordinator.onBackToWorkspaceDetail()

        // The per-workspace screen should be cleared
        let loaded = persistence.loadWorkspaceScreen(workspaceId: wsId)
        #expect(loaded == nil, "Per-workspace screen should be cleared after onBackToWorkspaceDetail")
    }

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
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))
        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-1", agentName: "Worker",
                noteId: nil, noteTitle: nil))

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.handleMissingWorkspace(workspaceId: wsId)

        // Both should be cleared
        #expect(persistence.loadLastScreen() == nil, "Last screen should be cleared")
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
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
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

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
            conversationAgentId: "agent-1")
        #expect(!repush, "Must not re-push the conversation when currentScreen is no longer .agentConversation")
    }

    @Test @MainActor func shouldRepushConversation_trueWhenStillOnSameConversation() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-1", workspaceId: "ws-1", agentName: "Worker"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1")
        #expect(repush, "Should re-push when the same conversation is still the current screen")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenAgentChangedAgain() {
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-2")
        #expect(!repush, "A stale re-push for a superseded agent must be dropped")
    }

    @Test @MainActor func shouldRepushConversation_falseWhenCoordinatorMovedToAnotherAgent() {
        // Coordinator moved on to a different agent before the view state re-synced:
        // the screen match must reject the stale re-push even though the pending
        // and view-state agent ids still agree.
        let repush = RootView.shouldRepushConversation(
            currentScreen: .agentConversation(agentId: "agent-2", workspaceId: "ws-1", agentName: "Other"),
            pendingAgentId: "agent-1",
            conversationAgentId: "agent-1")
        #expect(!repush, "Re-push must be dropped when the coordinator now shows a different conversation")
    }

    @Test @MainActor func onBackToWorkspaceDetail_fromConversation_setsWorkspaceDetail() {
        let wsId = "test-coord-back-from-conv-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let coordinator = AppCoordinator(persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")
        coordinator.onBackToWorkspaceDetail()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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
                screen: "conversation", workspaceId: wsId,
                agentId: "agent-1", agentName: "Worker",
                noteId: nil, noteTitle: nil))
        coordinator.onBackToWorkspaceDetail()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after repeated onBackToWorkspaceDetail, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Repeated onBackToWorkspaceDetail should still clear the per-workspace screen")
    }

    // MARK: - Fetch-driven workspace validation (lastUpdated race)

    private static func makeWorkspace(id: String, status: String? = nil,
                                      attention: String? = nil) -> Workspace {
        Workspace(
            id: id, title: "WS \(id)", branch: nil, baseRef: nil,
            status: status, activity: nil, displayStatus: nil,
            attention: attention,
            lastActivity: nil, updatedAt: nil,
            repositoryOwner: nil, repositoryName: nil, prStatus: nil,
            prNumber: nil, diffSummaryTotalFiles: nil, taskStatsTotal: nil,
            taskStatsCompleted: nil, taskStatsInProgress: nil,
            agentSummaryCount: nil, agentSummaryAgents: nil
        )
    }

    /// Let main-queue-hopping sinks and spawned validation tasks run.
    private static func drainMainQueue() async {
        try? await Task.sleep(nanoseconds: 200_000_000)
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
        #expect(store.workspaces.first?.attention == "none",
                "Opening a workspace must optimistically clear the local unread flag")
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
                screen: "workspaceDetail", workspaceId: wsId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))

        let store = WorkspaceStore(forTesting: true)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, attention: "unread")])
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.markSeen"] = ["workspace": ["id": wsId]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onConnectionSuccess()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("workspace.markSeen"))
        #expect(fake.paramsForMethod("workspace.markSeen").first?["workspaceId"] as? String == wsId)
        #expect(store.workspaces.first?.attention == "none",
                "Restoring into a workspace must clear the local unread flag")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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
            domain: "WebSocket", code: -32601,
            userInfo: [NSLocalizedDescriptionKey: "Method not found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
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
        #expect(persistence.loadLastScreen() == nil, "Last screen should be cleared")
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil, "Per-workspace screen should be cleared")
    }

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

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("An empty pre-fetch publish must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_archivedWorkspace_bootsToWorkspaceListFromConversation() async {
        let wsId = "test-coord-archived-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectAgent("agent-1", workspaceId: wsId, agentName: "Worker")

        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId, status: "archived")])
        await Self.drainMainQueue()

        if case .workspaceList = coordinator.currentScreen {
            // pass
        } else {
            Issue.record("Expected .workspaceList for archived workspace, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func firstFetch_existingWorkspace_staysOnDetail() async {
        let wsId = "test-coord-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let coordinator = AppCoordinator(workspaceStore: store, connection: FakeConnectionManager(), persistence: persistence)
        coordinator.onSelectWorkspace(wsId)

        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])
        await Self.drainMainQueue()

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .workspaceDetail, got \(coordinator.currentScreen)")
        }
    }

    // MARK: - Reconnect re-validation of the open conversation

    @Test @MainActor func repeatedReconnectAttemptsDoNotFanOutWorkspaceLoadingChanges() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        // Repeated connected events replace the pending reconnect attempt while
        // the overlay is still waiting for workspace loading to complete.
        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline + 1,
                "Only the current reconnect registration may receive a loading change")
        #expect(coordinator.isDisconnected)

        store.isLoading = false
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline + 2)
        #expect(!coordinator.isDisconnected,
                "The overlay must clear when workspace loading finishes")
    }

    @Test @MainActor func reconnectTimeoutRemovesWorkspaceLoadingObservation() async throws {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()

        try await Task.sleep(for: .milliseconds(5_200))
        #expect(!coordinator.isDisconnected)

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline,
                "A timed-out reconnect must not leave a loading callback registered")
    }

    @Test @MainActor func coordinatorDeallocationRemovesWorkspaceLoadingObservation() async {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        weak var weakCoordinator: AppCoordinator?

        do {
            var coordinator: AppCoordinator? = AppCoordinator(
                workspaceStore: store,
                connection: fake,
                persistence: persistence,
                reconnectLoadingObservationDidChange: {
                    callbackCount.withLock { $0 += 1 }
                })
            weakCoordinator = coordinator

            fake.simulateConnect()
            await Self.drainMainQueue()
            fake.simulateDisconnect()
            await Self.drainMainQueue()
            fake.simulateConnect()
            await Self.drainMainQueue()
            coordinator = nil
        }

        await Self.drainMainQueue()
        #expect(weakCoordinator == nil)

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()

        #expect(callbackCount.withLock { $0 } == baseline,
                "Deallocation must consume the pending loading registration")
    }

    @Test @MainActor func staleOverlayTimeoutDoesNotHideLaterDisconnection() async throws {
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        let callbackCount = Mutex(0)
        let coordinator = AppCoordinator(
            workspaceStore: store,
            connection: fake,
            persistence: persistence,
            reconnectLoadingObservationDidChange: {
                callbackCount.withLock { $0 += 1 }
            })

        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()
        fake.simulateConnect()
        await Self.drainMainQueue()
        fake.simulateDisconnect()
        await Self.drainMainQueue()

        #expect(coordinator.isDisconnected)
        try await Task.sleep(for: .milliseconds(5_200))
        #expect(coordinator.isDisconnected,
                "A timeout from the prior reconnect must not hide a later disconnection")

        let baseline = callbackCount.withLock { $0 }
        store.isLoading = true
        await Self.drainMainQueue()
        #expect(callbackCount.withLock { $0 } == baseline,
                "Disconnect must consume the pending loading registration")
    }

    @Test @MainActor func reconnect_missingAgent_bootsToWorkspaceDetail() async {
        let wsId = "test-coord-reconnect-gone-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.errorMap["agent.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "agent not found",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        // Seed the store so the reconnect overlay clears immediately.
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-gone", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"), "Reconnect must re-validate the open conversation's agent")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after reconnect with missing agent, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved sub-screen should be cleared for the missing agent")
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
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
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
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
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
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "Missing required parameter: agentId"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)
        store.publishFetchedWorkspaces([Self.makeWorkspace(id: wsId)])

        coordinator.onSelectAgent("agent-live", workspaceId: wsId, agentName: "Worker")
        fake.simulateConnect()
        fake.simulateDisconnect()
        fake.simulateConnect()
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("agent.get"))
        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
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
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingAgent, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved sub-screen should be cleared for the missing agent")
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

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
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

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-1")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another workspace must not navigate, got \(coordinator.currentScreen)")
        }
    }

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

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
            #expect(agentId == "agent-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingAgent for another agent must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
                "The live conversation's saved sub-screen must not be cleared")
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

        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after handleMissingNote, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved note screen should be cleared for the missing note")
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

        if case .agentConversation(let agentId, let wId, _) = coordinator.currentScreen {
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

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
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

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-b")
            #expect(wId == wsId)
        } else {
            Issue.record("handleMissingNote for another note must not navigate, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) != nil,
                "The live note screen's saved sub-screen must not be cleared")
    }

    // MARK: - Note validation on restore

    @Test @MainActor func onSelectWorkspace_restoredNoteMissing_fallsBackToDetail() async {
        let wsId = "test-coord-restore-dead-note-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-dead", noteTitle: "Dead Note"))

        // No workspace publish: keep lastUpdated nil so the workspace-existence
        // validation stays inert and only the note validation path is exercised.
        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // note.get answers -32602 with data.code == "not-found" for a
        // nonexistent note (docs/PROTOCOL.md §3.3/§9)
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -32602,
            userInfo: [NSLocalizedDescriptionKey: "note not found",
                       NSError.intentErrorDataCodeKey: "not-found"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"), "Restoring a note screen must re-validate the note")
        if case .workspaceDetail(let wId) = coordinator.currentScreen {
            #expect(wId == wsId)
        } else {
            Issue.record("Expected .workspaceDetail after restoring a missing note, got \(coordinator.currentScreen)")
        }
        #expect(persistence.loadWorkspaceScreen(workspaceId: wsId) == nil,
                "Per-workspace saved note screen should be cleared for the missing note")
    }

    @Test @MainActor func onSelectWorkspace_restoredNoteTransientError_staysOnNote() async {
        let wsId = "test-coord-restore-note-transient-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-1", noteTitle: "Flaky Network Note"))

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        // Transport-level timeout must not read as deletion
        fake.errorMap["note.get"] = NSError(
            domain: "WebSocket", code: -2,
            userInfo: [NSLocalizedDescriptionKey: "Request timed out"])
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-1")
            #expect(wId == wsId)
        } else {
            Issue.record("Transient note.get error must not navigate away, got \(coordinator.currentScreen)")
        }
    }

    @Test @MainActor func onSelectWorkspace_restoredNoteAlive_staysOnNote() async {
        let wsId = "test-coord-restore-note-alive-\(UUID().uuidString)"
        defer {
            persistence.clearWorkspaceScreen(workspaceId: wsId)
            cleanupLastScreen()
        }

        persistence.saveWorkspaceScreen(
            workspaceId: wsId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: wsId,
                agentId: nil, agentName: nil,
                noteId: "note-live", noteTitle: "Live Note"))

        let store = WorkspaceStore(forTesting: true)
        let fake = FakeConnectionManager()
        fake.responseMap["note.get"] = ["note": [
            "id": "note-live", "title": "Live Note", "content": "hello"
        ] as [String: Any]] as [String: Any]
        let coordinator = AppCoordinator(workspaceStore: store, connection: fake, persistence: persistence)

        coordinator.onSelectWorkspace(wsId)
        await Self.drainMainQueue()

        #expect(fake.didCallMethod("note.get"))
        if case .noteDetail(let noteId, let wId, _) = coordinator.currentScreen {
            #expect(noteId == "note-live")
            #expect(wId == wsId)
        } else {
            Issue.record("Expected to stay on .noteDetail for a live note, got \(coordinator.currentScreen)")
        }
    }
}

