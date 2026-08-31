import SwiftUI
import Combine
import Observation

enum AppScreen {
    case loading
    case pairing
    case connecting
    case connectionFailed(error: String)
    case workspaceList
    case workspaceDetail(workspaceId: String)
    case agentConversation(agentId: String, workspaceId: String, agentName: String)
    case noteDetail(noteId: String, workspaceId: String, noteTitle: String)
    case settings
    case disconnected
}

@MainActor
@Observable
class AppCoordinator {
    var currentScreen: AppScreen = .loading
    var isDisconnected = false
    /// True when the pairing surface should also offer the remaining saved
    /// connections (e.g. after logging off the active connection while others
    /// are still saved). The Connect to… screen reads this flag.
    var pairingShowsSavedConnections = false
    @ObservationIgnored private var hasEverConnected = false
    /// Set to true to suppress didSet side effects on selectedWorkspaceId
    @ObservationIgnored private var suppressWorkspaceNavigation = false

    var selectedWorkspaceId: String? {
        didSet {
            if let workspaceId = selectedWorkspaceId, selectedWorkspaceId != oldValue, !suppressWorkspaceNavigation {
                currentScreen = .workspaceDetail(workspaceId: workspaceId)
            }
        }
    }

    var currentScreenDescription: String {
        String(describing: currentScreen)
    }
    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var certMismatchObserver: AnyCancellable?
    @ObservationIgnored private var reconnectLoadingObservationID: UUID?
    /// Intentionally tracked so mutating it consumes the current one-shot
    /// workspace-loading registration before that registration is abandoned.
    private var reconnectLoadingObservationGeneration = 0
    @ObservationIgnored private var reconnectOverlayTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private let reconnectLoadingObservationDidChange: @Sendable () -> Void

    @ObservationIgnored private let workspaceStore: WorkspaceStore
    @ObservationIgnored private let connection: ConnectionManagerRouting
    @ObservationIgnored private let persistence: PersistenceManager
    @ObservationIgnored private let syncedRegistry: SyncedBackendRegistry

    init(workspaceStore: WorkspaceStore = WorkspaceStore.shared,
         connection: ConnectionManagerRouting = ConnectionManager.shared,
         persistence: PersistenceManager = PersistenceManager.shared,
         syncedRegistry: SyncedBackendRegistry = SyncedBackendRegistry(),
         reconnectLoadingObservationDidChange: @escaping @Sendable () -> Void = {}) {
        self.workspaceStore = workspaceStore
        self.connection = connection
        self.persistence = persistence
        self.syncedRegistry = syncedRegistry
        self.reconnectLoadingObservationDidChange = reconnectLoadingObservationDidChange
        startObservingConnection()
        startObservingCertMismatch()
        startObservingWorkspaceList()
    }

    isolated deinit {
        reconnectOverlayTimeoutTask?.cancel()
        cancelReconnectLoadingObservation()
    }

    private func startObservingConnection() {
        connectionObserver = connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .reconnecting, .disconnected:
                    self.cancelReconnectLoadingObservation()
                    self.reconnectOverlayTimeoutTask?.cancel()
                    self.reconnectOverlayTimeoutTask = nil
                    if self.hasEverConnected {
                        self.isDisconnected = true
                    }
                case .connected:
                    let wasDisconnected = self.isDisconnected
                    self.hasEverConnected = true
                    if wasDisconnected {
                        // On reconnection, wait for workspace data to load before
                        // clearing the overlay so the UI doesn't flash blank metadata.
                        self.waitForWorkspaceLoadThenClearOverlay()
                        // The agent shown in an open conversation may have been
                        // deleted while disconnected — re-validate it. (Workspace
                        // validation follows from the reconnect fetchAll.)
                        self.revalidateCurrentAgentAfterReconnect()
                    } else {
                        // Initial connection — isDisconnected was never true, nothing to clear.
                    }
                default:
                    break
                }
            }
    }

    /// After a reconnect, re-run agent validation if the current screen is a conversation.
    private func revalidateCurrentAgentAfterReconnect() {
        if case .agentConversation(let agentId, let workspaceId, _) = currentScreen {
            Task { @MainActor in
                await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
            }
        }
    }

    /// Wait for WorkspaceStore to finish loading before clearing the reconnection overlay.
    /// Falls back to a 5-second timeout so the overlay never gets stuck.
    private func waitForWorkspaceLoadThenClearOverlay() {
        // Cancel any previous observer from a prior reconnection attempt
        cancelReconnectLoadingObservation()
        reconnectOverlayTimeoutTask?.cancel()
        reconnectOverlayTimeoutTask = nil

        // If WorkspaceStore is not currently loading (fetchAll already completed
        // or hasn't started yet), check if data is already available.
        if !workspaceStore.isLoading && workspaceStore.lastUpdated != nil {
            self.isDisconnected = false
            return
        }

        // Observe isLoading: wait for it to go from true → false (fetchAll completed).
        let observationID = UUID()
        reconnectLoadingObservationID = observationID
        observeWorkspaceLoading(observationID: observationID)

        // Timeout: if the fetch takes too long or fails silently, clear the overlay anyway.
        reconnectOverlayTimeoutTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.reconnectOverlayTimeoutTask = nil
            if self.isDisconnected {
                self.cancelReconnectLoadingObservation()
                self.isDisconnected = false
            }
        }
    }

    private func cancelReconnectLoadingObservation() {
        guard reconnectLoadingObservationID != nil else { return }
        reconnectLoadingObservationID = nil
        reconnectLoadingObservationGeneration &+= 1
    }

    private func observeWorkspaceLoading(observationID: UUID) {
        let observationDidChange = reconnectLoadingObservationDidChange
        withObservationTracking {
            _ = workspaceStore.isLoading
            _ = reconnectLoadingObservationGeneration
        } onChange: { [weak self] in
            observationDidChange()
            Task { @MainActor [weak self] in
                guard let self,
                      self.reconnectLoadingObservationID == observationID else { return }
                if self.workspaceStore.isLoading {
                    self.observeWorkspaceLoading(observationID: observationID)
                } else {
                    self.reconnectOverlayTimeoutTask?.cancel()
                    self.reconnectOverlayTimeoutTask = nil
                    self.cancelReconnectLoadingObservation()
                    self.isDisconnected = false
                }
            }
        }
    }


    private func startObservingCertMismatch() {
        certMismatchObserver = ConnectionManager.shared.certMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mismatch in
                guard let self = self, mismatch else { return }
                self.currentScreen = .connectionFailed(error: "Server certificate has changed. Please re-pair your device.")
                // Reset the flag so it doesn't re-trigger
                ConnectionManager.shared.certMismatchDetected = false
            }
    }

    private func startObservingWorkspaceList() {
        withObservationTracking {
            _ = workspaceStore.lastUpdated
            _ = workspaceStore.workspaces
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.startObservingWorkspaceList()
                // Only validate after workspaces have been fetched at least once
                guard self.workspaceStore.lastUpdated != nil else { return }
                self.validateCurrentWorkspaceExists(in: self.workspaceStore.workspaces)
            }
        }
    }

    /// If the current screen references a workspace that no longer exists, navigate to workspace list.
    private func validateCurrentWorkspaceExists(in workspaces: [Workspace]) {
        let workspaceId: String?
        switch currentScreen {
        case .workspaceDetail(let id):
            workspaceId = id
        case .agentConversation(_, let id, _):
            workspaceId = id
        case .noteDetail(_, let id, _):
            workspaceId = id
        default:
            return
        }
        guard let wsId = workspaceId else { return }

        // Check if workspace exists at all
        guard let workspace = workspaces.first(where: { $0.id == wsId }) else {
            handleMissingWorkspace(workspaceId: wsId)
            return
        }

        // Check if workspace is archived or deleted
        let status = workspace.status?.lowercased() ?? ""
        if status == "archived" || status == "deleted" {
            handleMissingWorkspace(workspaceId: wsId)
        }
    }

    func onLoadComplete() {
        refreshSyncedBackends()
        if DemoMode.pretendPaired || persistence.activeConnection() != nil {
            currentScreen = .connecting
        } else {
            // Synced connections merged from the registry (or connections
            // saved earlier) must be offered on the pairing surface.
            pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
            currentScreen = .pairing
        }
    }

    /// Called when the scene becomes active (launch and every return to the
    /// foreground): re-merges the iCloud-synced backend registry so changes
    /// made on other devices while the app was backgrounded show up.
    func onScenePhaseActive() {
        refreshSyncedBackends()
    }

    /// Merges the iCloud-synced backend registry into the saved connections
    /// (see `SyncedBackendConnectionMerge`). An unavailable registry read
    /// (locked keychain, missing entitlement) is a no-op — existing local
    /// knowledge is kept. When a tombstone removes the active connection,
    /// disconnects and routes to the pairing surface like Log Off. When the
    /// merge rewrote the active connection's record (rotated token, new
    /// routes), the live ConnectionManager cache adopts the new fields so
    /// the next reconnect uses them.
    @discardableResult
    func refreshSyncedBackends() -> SyncedBackendMergeOutcome? {
        guard case .available(let records) = syncedRegistry.listBackends() else { return nil }
        let outcome = persistence.mergeSyncedBackends(records: records)
        if outcome.removedActiveConnection {
            hasEverConnected = false
            isDisconnected = false
            ConnectionManager.shared.disconnect()
            resetWorkspaceStore()
            persistence.clearLastScreen()
            selectedWorkspaceId = nil
            pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
            currentScreen = .pairing
        } else if outcome.changed {
            if let active = persistence.activeConnection(),
                outcome.updatedIds.contains(active.id)
            {
                ConnectionManager.shared.updateCachedCredentials(
                    hosts: active.server.hosts, port: active.server.port,
                    token: active.token, certFingerprint: active.server.certFingerprint)
            }
            // A merge while the pairing surface is up must (un)offer the
            // saved connections it added/removed.
            if case .pairing = currentScreen {
                pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
            }
        }
        return outcome
    }

    func onConnectionSuccess() {
        // Try to restore last viewed screen. Restoring into a workspace counts
        // as viewing it, so it marks the workspace seen — mirroring the FE,
        // where the workspace surface marks seen whenever it becomes active
        // (including cold-start restore).
        if let saved = persistence.loadLastScreen() {
            switch saved.screen {
            case "workspaceDetail":
                if let workspaceId = saved.workspaceId {
                    markWorkspaceSeen(workspaceId)
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .workspaceDetail(workspaceId: workspaceId)
                    return
                }
            case "conversation":
                if let agentId = saved.agentId,
                   let workspaceId = saved.workspaceId,
                   let agentName = saved.agentName {
                    markWorkspaceSeen(workspaceId)
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .agentConversation(
                        agentId: agentId, workspaceId: workspaceId, agentName: agentName)
                    // Validate agent still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
                    }
                    return
                }
            case "note":
                if let noteId = saved.noteId,
                   let workspaceId = saved.workspaceId,
                   let noteTitle = saved.noteTitle {
                    markWorkspaceSeen(workspaceId)
                    suppressWorkspaceNavigation = true
                    selectedWorkspaceId = workspaceId
                    suppressWorkspaceNavigation = false
                    currentScreen = .noteDetail(
                        noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
                    // Validate note still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredNote(noteId: noteId, workspaceId: workspaceId)
                    }
                    return
                }
            default:
                break
            }
        }
        currentScreen = .workspaceList
    }

    func onConnectionFailed(error: String) {
        currentScreen = .connectionFailed(error: error)
    }

    func onRetryConnection() {
        currentScreen = .connecting
    }

    func onReconnect() {
        pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
        currentScreen = .pairing
    }

    func onPaired() {
        pairingShowsSavedConnections = false
        currentScreen = .connecting
    }

    /// Drop the previous daemon's workspace data so no stale rows are shown
    /// after reconnecting, and so ConnectingView's waitForWorkspaceData
    /// (which polls lastUpdated == nil) genuinely waits for the new daemon.
    private func resetWorkspaceStore() {
        WorkspaceStore.shared.workspaces = []
        WorkspaceStore.shared.lastUpdated = nil
    }

    /// Switch to another saved connection: drop the live connection, clear the
    /// saved screen state, make the target connection active, and reconnect.
    func onSwitchConnection(id: UUID) {
        hasEverConnected = false
        isDisconnected = false
        ConnectionManager.shared.disconnect()
        resetWorkspaceStore()
        persistence.clearLastScreen()
        persistence.setActiveConnection(id: id)
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = false
        currentScreen = .connecting
    }

    /// Delete a saved connection. Deleting the active one disconnects and routes
    /// like Log Off: pairing surface, with the remaining saved connections
    /// offered when any are left.
    func onDeleteConnection(id: UUID) {
        let wasActive = persistence.activeConnection()?.id == id
        persistence.deleteConnection(id: id)
        let hasRemaining = !persistence.loadConnections().isEmpty
        if wasActive {
            hasEverConnected = false
            isDisconnected = false
            ConnectionManager.shared.disconnect()
            resetWorkspaceStore()
            persistence.clearLastScreen()
            selectedWorkspaceId = nil
            pairingShowsSavedConnections = hasRemaining
            currentScreen = .pairing
        } else if !hasRemaining {
            pairingShowsSavedConnections = false
        }
    }

    func onOpenSettings() {
        currentScreen = .settings
    }

    /// Log Off forgets the active connection only. If other saved connections
    /// remain, the pairing surface is shown with those connections available;
    /// otherwise it behaves like first-run pairing.
    func onLogOff() {
        hasEverConnected = false
        isDisconnected = false
        ConnectionManager.shared.disconnect()
        resetWorkspaceStore()
        if let active = persistence.activeConnection() {
            persistence.deleteConnection(id: active.id)
        }
        persistence.clearLastScreen()
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
        currentScreen = .pairing
    }

    func onSelectWorkspace(_ workspaceId: String) {
        markWorkspaceSeen(workspaceId)
        // Check for a saved per-workspace sub-screen and restore it
        if let saved = persistence.loadWorkspaceScreen(workspaceId: workspaceId) {
            suppressWorkspaceNavigation = true
            selectedWorkspaceId = workspaceId
            suppressWorkspaceNavigation = false
            switch saved.screen {
            case "conversation":
                if let agentId = saved.agentId, let agentName = saved.agentName {
                    currentScreen = .agentConversation(
                        agentId: agentId, workspaceId: workspaceId, agentName: agentName)
                    saveCurrentScreen()
                    // Validate agent still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredAgent(agentId: agentId, workspaceId: workspaceId)
                    }
                    return
                }
            case "note":
                if let noteId = saved.noteId, let noteTitle = saved.noteTitle {
                    currentScreen = .noteDetail(
                        noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
                    saveCurrentScreen()
                    // Validate note still exists asynchronously
                    Task { @MainActor in
                        await self.validateRestoredNote(noteId: noteId, workspaceId: workspaceId)
                    }
                    return
                }
            default:
                break
            }
        }
        selectedWorkspaceId = workspaceId
        currentScreen = .workspaceDetail(workspaceId: workspaceId)
        saveCurrentScreen()
    }

    /// Fire-and-forget workspace.markSeen: clears the server-owned unread
    /// attention flag (blue dot) across clients when the user opens a
    /// workspace, mirroring the FE. Failures are logged and ignored — an
    /// older daemon without the method just keeps its legacy behavior.
    private func markWorkspaceSeen(_ workspaceId: String) {
        workspaceStore.clearUnreadAttentionLocally(workspaceId: workspaceId)
        Task { @MainActor in
            do {
                _ = try await connection.request(
                    "workspace.markSeen", params: ["workspaceId": workspaceId])
            } catch {
                AppLog.app.error("[AppCoordinator] workspace.markSeen failed: \(error)")
            }
        }
    }

    /// Called when a restored workspace is no longer found in the workspace list.
    /// Navigates back to the workspace list and clears all saved screen state for that workspace.
    func handleMissingWorkspace(workspaceId: String) {
        persistence.clearWorkspaceScreen(workspaceId: workspaceId)
        persistence.clearLastScreen()
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
    }

    func onBackToWorkspaceList() {
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList", workspaceId: nil,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil))
    }

    func onSelectAgent(_ agentId: String, workspaceId: String, agentName: String) {
        suppressWorkspaceNavigation = true
        selectedWorkspaceId = workspaceId
        suppressWorkspaceNavigation = false
        currentScreen = .agentConversation(agentId: agentId, workspaceId: workspaceId, agentName: agentName)
        saveCurrentScreen()
        // Save per-workspace sub-screen
        persistence.saveWorkspaceScreen(
            workspaceId: workspaceId,
            screen: PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: workspaceId,
                agentId: agentId, agentName: agentName, noteId: nil, noteTitle: nil))
    }

    func onSelectNote(_ noteId: String, workspaceId: String, noteTitle: String) {
        currentScreen = .noteDetail(noteId: noteId, workspaceId: workspaceId, noteTitle: noteTitle)
        saveCurrentScreen()
        // Save per-workspace sub-screen
        persistence.saveWorkspaceScreen(
            workspaceId: workspaceId,
            screen: PersistenceManager.SavedScreen(
                screen: "note", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: noteId, noteTitle: noteTitle))
    }

    func onBackFromNote() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
            // Clear per-workspace sub-screen so re-entering the workspace shows the detail view.
            persistence.clearWorkspaceScreen(workspaceId: workspaceId)
        }
    }

    func onBackToWorkspaceDetail() {
        if let workspaceId = selectedWorkspaceId {
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
            // Clear per-workspace sub-screen so re-entering the workspace shows the detail view.
            persistence.clearWorkspaceScreen(workspaceId: workspaceId)
        }
    }

    // MARK: - Screen Persistence

    private func saveCurrentScreen() {
        let saved: PersistenceManager.SavedScreen
        switch currentScreen {
        case .workspaceDetail(let workspaceId):
            saved = PersistenceManager.SavedScreen(
                screen: "workspaceDetail", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil)
        case .agentConversation(let agentId, let workspaceId, let agentName):
            saved = PersistenceManager.SavedScreen(
                screen: "conversation", workspaceId: workspaceId,
                agentId: agentId, agentName: agentName, noteId: nil, noteTitle: nil)
        case .noteDetail(let noteId, let workspaceId, let noteTitle):
            saved = PersistenceManager.SavedScreen(
                screen: "note", workspaceId: workspaceId,
                agentId: nil, agentName: nil, noteId: noteId, noteTitle: noteTitle)
        default:
            return
        }
        persistence.saveLastScreen(saved)
    }

    /// Validates that a restored agent still exists. Only a definitive not-found falls back —
    /// transient/transport errors leave the screen in place (the conversation load re-validates).
    private func validateRestoredAgent(agentId: String, workspaceId: String) async {
        do {
            let result = try await connection.request(
                "agent.get",
                params: ["agentId": agentId, "workspaceId": workspaceId]
            )
            // A missing or malformed result is not a valid agent payload.
            if (result as? [String: Any]) == nil {
                handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
            }
        } catch {
            AppLog.app.error("[AppCoordinator] Agent validation failed: \(error)")
            // Only a definitive not-found (-32602 with data.code == "not-found",
            // PROTOCOL §3.3/§9) reads as deletion.
            let nsError = error as NSError
            if nsError.isEntityNotFound {
                handleMissingAgent(agentId: agentId, workspaceId: workspaceId)
            } else if nsError.domain == "WebSocket" && nsError.code == -32602 {
                AppLog.app.warning(
                    "[AppCoordinator] UNEXPECTED -32602 without data.code == \"not-found\" for "
                        + "agent \(agentId) (data.code: \(nsError.intentErrorDataCode ?? "absent")) — "
                        + "NOT treating as deletion: \(nsError.localizedDescription)")
            }
        }
    }

    /// Called when the agent being viewed is no longer found (restore validation,
    /// not-found at conversation load, or deletion while open).
    /// Falls back to the workspace detail (agent list).
    func handleMissingAgent(agentId: String, workspaceId: String) {
        // Only redirect if we're still viewing this agent's conversation — a stale
        // validation must not evict a different conversation in the same workspace.
        if case .agentConversation(let aId, let wsId, _) = currentScreen,
           aId == agentId, wsId == workspaceId {
            persistence.clearWorkspaceScreen(workspaceId: workspaceId)
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    /// Validates that a restored note still exists. Only a definitive not-found falls back —
    /// transient/transport errors leave the screen in place.
    func validateRestoredNote(noteId: String, workspaceId: String, noteStore: NoteStore? = nil) async {
        let store = noteStore ?? NoteStore(connectionManager: connection)
        if case .notFound = await store.fetchNote(noteId: noteId, workspaceId: workspaceId) {
            handleMissingNote(noteId: noteId, workspaceId: workspaceId)
        }
    }

    /// Called when the note being viewed no longer exists. Falls back to the workspace detail view.
    func handleMissingNote(noteId: String, workspaceId: String) {
        // Only redirect if we're still viewing this note — a stale validation
        // must not evict a different note screen in the same workspace.
        if case .noteDetail(let nId, let wsId, _) = currentScreen,
           nId == noteId, wsId == workspaceId {
            persistence.clearWorkspaceScreen(workspaceId: workspaceId)
            currentScreen = .workspaceDetail(workspaceId: workspaceId)
            saveCurrentScreen()
        }
    }

    func onSettingsBack() {
        currentScreen = .workspaceList
    }
}

