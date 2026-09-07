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

/// A pairing request delivered via an `intent://pair` deep link, awaiting
/// explicit user confirmation before any connection is attempted — unlike the
/// in-app camera scan, a deep link can be triggered by any web page.
struct DeepLinkPairingRequest: Identifiable, Equatable {
    let id = UUID()
    let payload: PairingPayload
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
    /// Deep-link pairing awaiting user confirmation; drives the
    /// DeepLinkPairingView sheet in RootView.
    var pendingDeepLinkPairing: DeepLinkPairingRequest?
    /// Keys ConnectingView's one-shot connection-attempt task. Bumped by
    /// onSwitchConnection so a switch performed while currentScreen is
    /// already .connecting (e.g. a deep-link pairing confirmed over the
    /// cold-start connect) restarts the attempt — SwiftUI would otherwise
    /// keep the existing ConnectingView and never re-run its task.
    private(set) var connectionAttemptId = 0
    @ObservationIgnored private var hasEverConnected = false
    @ObservationIgnored private var hasLoadCompleted = false
    /// Pair payload from a URL that arrived before onLoadComplete (cold
    /// start); surfaced as pendingDeepLinkPairing once load finishes.
    @ObservationIgnored private var stashedDeepLinkPayload: PairingPayload?
    /// Notification selection awaiting completion of connection or retry routing.
    @ObservationIgnored private var pendingNotificationSelection: (
        agentId: String, workspaceId: String, agentName: String, connectionId: UUID
    )?
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
    @ObservationIgnored private let connection: any SessionConnectionManaging
    /// The backend this coordinator's window is bound to; nil only for a
    /// window that has no backend yet (pairing session). Bound windows route
    /// straight to .connecting on load and dial this backend's saved record.
    @ObservationIgnored let backendID: BackendID?
    @ObservationIgnored private let persistence: PersistenceManager
    @ObservationIgnored private let sessionRegistry: BackendSessionRegistry
    @ObservationIgnored private let syncedRegistry: SyncedBackendRegistry
    @ObservationIgnored private let backgroundTaskManager: BackgroundTaskManager
    @ObservationIgnored private let claimScreenRestoration: @MainActor () -> Bool
    @ObservationIgnored private var claimedScreenRestoration: Bool?
    /// Rebinds this coordinator's window to another backend, set by the
    /// window root (BackendWindowRoot). On single-window platforms it
    /// retargets the window in place; where multiple windows are supported
    /// it opens/raises the target backend's window instead (window model
    /// v2: a bound multi-window scene never retargets). When unset (tests,
    /// previews), switch/pair actions fall back to in-place routing over
    /// this session's connection.
    @ObservationIgnored var retargetWindow: ((BackendID) -> Void)?

    /// Whether this coordinator owns the session's last-screen persistence.
    /// Only the first window per backend session restores and saves that
    /// backend's screen; duplicated windows start at the workspace list.
    /// The claim is consumed lazily on first use so coordinators built for
    /// discarded SwiftUI view constructions never spend it.
    private var restoresLastScreen: Bool {
        if let claimed = claimedScreenRestoration { return claimed }
        let claimed = claimScreenRestoration()
        claimedScreenRestoration = claimed
        return claimed
    }

    init(workspaceStore: WorkspaceStore,
         connection: any SessionConnectionManaging,
         backendID: BackendID? = nil,
         persistence: PersistenceManager = PersistenceManager.shared,
         sessionRegistry: BackendSessionRegistry = .shared,
         syncedRegistry: SyncedBackendRegistry = SyncedBackendRegistry(),
         backgroundTaskManager: BackgroundTaskManager = BackgroundTaskManager(),
         reconnectLoadingObservationDidChange: @escaping @Sendable () -> Void = {},
         claimScreenRestoration: @escaping @MainActor () -> Bool = { true }) {
        self.workspaceStore = workspaceStore
        self.connection = connection
        self.backendID = backendID
        self.persistence = persistence
        self.sessionRegistry = sessionRegistry
        self.syncedRegistry = syncedRegistry
        self.backgroundTaskManager = backgroundTaskManager
        self.reconnectLoadingObservationDidChange = reconnectLoadingObservationDidChange
        self.claimScreenRestoration = claimScreenRestoration
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
                try await Task.sleep(for: Constants.AppCoordination.reconnectOverlayTimeout)
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
        certMismatchObserver = connection.certMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mismatch in
                guard let self = self, mismatch else { return }
                self.currentScreen = .connectionFailed(error: "Server certificate has changed. Please re-pair your device.")
                // Reset the flag so it doesn't re-trigger
                self.connection.certMismatchDetected = false
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
        hasLoadCompleted = true
        refreshSyncedBackends()
        if DemoMode.pretendPaired || backendID != nil {
            currentScreen = .connecting
        } else {
            // Synced connections merged from the registry (or connections
            // saved earlier) must be offered on the pairing surface.
            pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
            currentScreen = .pairing
        }
        // A deep link that arrived during the cold-start load is surfaced
        // now, over whichever screen the load routed to.
        if let payload = stashedDeepLinkPayload {
            stashedDeepLinkPayload = nil
            pendingDeepLinkPairing = DeepLinkPairingRequest(payload: payload)
        }
    }

    // MARK: - Deep links (intent:// URLs)

    /// Entry point for `intent://` URLs (IntentApp.onOpenURL). Only
    /// `intent://pair` URIs are actionable: they surface a confirmation
    /// (DeepLinkPairingView) before any connection is attempted. Every other
    /// or malformed `intent://` URL is ignored without disturbing app state.
    /// The URL itself is never logged — pair payloads carry the auth token.
    func handleIncomingURL(_ url: URL) {
        guard let payload = PairingPayload.parse(url.absoluteString) else {
            AppLog.app.info("[AppCoordinator] Ignoring non-pairing deep link")
            return
        }
        guard hasLoadCompleted else {
            // Cold start: the URL can arrive before onLoadComplete has routed
            // to the first screen — stash it and surface it after load.
            stashedDeepLinkPayload = payload
            return
        }
        pendingDeepLinkPairing = DeepLinkPairingRequest(payload: payload)
    }

    /// A deep-link pairing connected and persisted successfully.
    ///
    /// A re-pair of this window's own backend (same record id, e.g. a
    /// rotated token) restarts this window's attempt so it dials the
    /// refreshed record. Any other pairing routes to the new backend via
    /// onPaired: the window root's retarget hook applies the v2 policy
    /// (rebind in place on single-window platforms; open/raise the new
    /// backend's window — or replace an unbound pairing window with it —
    /// where multiple windows are supported).
    func onDeepLinkPaired(_ connection: StoredConnection) {
        pendingDeepLinkPairing = nil
        if let bound = backendID, bound.connectionID == connection.id {
            self.connection.updateCachedCredentials(
                hosts: connection.server.hosts, port: connection.server.port,
                token: connection.token,
                certFingerprint: connection.server.certFingerprint,
                tcAddress: connection.server.tcAddress)
            connectionAttemptId += 1
            currentScreen = .connecting
            return
        }
        onPaired(connection)
    }

    /// A pairing completed over this window's session (QR scan, manual
    /// entry, or deep link for another backend): route to the paired
    /// backend's window. The window root's retarget hook applies the
    /// v2 policy (rebind in place vs open/raise); without a hook (tests,
    /// previews) the pairing session's live connection is used in place.
    func onPaired(_ connection: StoredConnection) {
        if let retargetWindow {
            let target = BackendID(connection.id)
            retargetWindow(target)
            // The pairing dialed the new backend over THIS window's live
            // session connection. Where multiple windows are supported the
            // retarget opened/raised the target's own window and this window
            // keeps its binding — re-dial its own backend or it keeps showing
            // the newly paired daemon's data over the hijacked socket. On
            // single-window platforms the retarget rebinds this window in
            // place (session torn down and replaced), so the repair state is
            // discarded with the old session.
            if let bound = backendID, bound != target {
                redialWindowBackend()
            }
            return
        }
        if case .pairing = currentScreen {
            pairingShowsSavedConnections = false
            onConnectionSuccess()
        } else {
            onSwitchConnection(id: connection.id)
        }
    }

    /// The connection identity this window shows: the bound backend's, if
    /// any.
    private var windowConnectionID: UUID? {
        backendID?.connectionID
    }

    /// The saved connection record this window shows: the bound backend's
    /// record. Settings renders it and Log Off forgets it — always scoped
    /// to this window's backend, never a global pointer.
    var windowConnection: StoredConnection? {
        guard let backendID else { return nil }
        return persistence.loadConnections().first { $0.id == backendID.connectionID }
    }

    /// Routes notification taps immediately once the connected UI is stable,
    /// or stashes them until cold-start connection routing completes. Taps
    /// for a backend this window doesn't show are dropped (the multi-window
    /// tap route opens the source backend's own window instead).
    func handleNotificationSelection(
        agentId: String,
        workspaceId: String,
        agentName: String,
        connectionId: UUID
    ) {
        guard windowConnectionID == connectionId else { return }
        switch currentScreen {
        case .loading, .connecting, .pairing, .connectionFailed, .disconnected:
            pendingNotificationSelection = (agentId, workspaceId, agentName, connectionId)
        default:
            onSelectAgent(agentId, workspaceId: workspaceId, agentName: agentName)
        }
    }

    /// Called when the scene becomes active (launch and every return to the
    /// foreground): re-merges the iCloud-synced backend registry so changes
    /// made on other devices while the app was backgrounded show up.
    func onScenePhaseActive() {
        backgroundTaskManager.endIfNeeded()
        refreshSyncedBackends()
    }

    /// Called when the scene leaves the foreground so agent-completion events
    /// can continue arriving during iOS's extended background execution window.
    func onScenePhaseNotActive() {
        backgroundTaskManager.beginIfNeeded()
    }

    /// Merges the iCloud-synced backend registry into the saved connections
    /// (see `SyncedBackendConnectionMerge`). An unavailable registry read
    /// (locked keychain, missing entitlement) is a no-op — existing local
    /// knowledge is kept. When a tombstone removes this window's backend,
    /// disconnects and routes away like Log Off (the window root's removal
    /// observation closes or rebinds the window). When the merge rewrote
    /// this window's record (rotated token, new routes), the live
    /// ConnectionManager cache adopts the new fields so the next reconnect
    /// uses them.
    @discardableResult
    func refreshSyncedBackends() -> SyncedBackendMergeOutcome? {
        guard case .available(let records) = syncedRegistry.listBackends() else { return nil }
        let windowID = windowConnectionID
        let outcome = persistence.mergeSyncedBackends(records: records)
        // Tombstones close windows on the removed backends; a re-added
        // record (same id resurrected from another device) clears its mark.
        sessionRegistry.markBackendsRemoved(outcome.removedIds.map(BackendID.init))
        sessionRegistry.clearRemovedMarks(outcome.addedIds.map(BackendID.init))
        for removedId in outcome.removedIds {
            persistence.clearLastScreen(for: removedId)
        }
        if let windowID, outcome.removedIds.contains(windowID) {
            exitRemovedBackend()
        } else if outcome.changed {
            if let record = windowConnection,
                outcome.updatedIds.contains(record.id)
            {
                connection.updateCachedCredentials(
                    hosts: record.server.hosts, port: record.server.port,
                    token: record.token, certFingerprint: record.server.certFingerprint,
                    tcAddress: record.server.tcAddress)
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
        if let selection = pendingNotificationSelection {
            pendingNotificationSelection = nil
            if windowConnectionID == selection.connectionId {
                onSelectAgent(
                    selection.agentId,
                    workspaceId: selection.workspaceId,
                    agentName: selection.agentName
                )
                return
            }
        }

        // Try to restore this backend's last viewed screen. Restoring into a
        // workspace counts as viewing it, so it marks the workspace seen —
        // mirroring the FE, where the workspace surface marks seen whenever
        // it becomes active (including cold-start restore). Only the session's
        // first window restores; other windows land on the workspace list.
        if restoresLastScreen, let connectionID = windowConnectionID,
           let saved = persistence.loadLastScreen(for: connectionID) {
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

    /// Drop the previous daemon's workspace data so no stale rows are shown
    /// after reconnecting, and so ConnectingView's waitForWorkspaceData
    /// (which polls lastUpdated == nil) genuinely waits for the new daemon.
    private func resetWorkspaceStore() {
        workspaceStore.workspaces = []
        workspaceStore.lastUpdated = nil
    }

    /// Re-dial this window's own backend after its live session connection
    /// was used to pair a different one (onPaired's bound multi-window
    /// route): drop the hijacked socket and the other daemon's workspace
    /// data, then restart the attempt — ConnectingView dials from
    /// windowConnection, this window's own saved record.
    private func redialWindowBackend() {
        hasEverConnected = false
        isDisconnected = false
        connection.disconnect()
        resetWorkspaceStore()
        connectionAttemptId += 1
        currentScreen = .connecting
    }

    /// In-place route-out for a backend this window may no longer show —
    /// Log Off, deleting this window's connection, or a synced tombstone:
    /// drop the live connection and land on the pairing surface, offering
    /// any remaining saved connections. In the running app the window root's
    /// removal observation supersedes this (it closes the window or rebinds
    /// it to a fresh pairing session); this in-place routing covers windows
    /// without a root hook (tests, previews).
    private func exitRemovedBackend() {
        hasEverConnected = false
        isDisconnected = false
        connection.disconnect()
        resetWorkspaceStore()
        if let connectionID = windowConnectionID {
            persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = !persistence.loadConnections().isEmpty
        currentScreen = .pairing
    }

    /// Switch this window to another saved connection. Marks the target as
    /// the last-used backend and clears its saved screen state (a switch
    /// lands on the workspace list, as before), then routes to its window
    /// via the root's retarget hook (rebind in place on single-window
    /// platforms; open/raise where multiple windows are supported). Without
    /// a hook (tests, previews) falls back to dialing in place.
    func onSwitchConnection(id: UUID) {
        persistence.setActiveConnection(id: id)
        persistence.clearLastScreen(for: id)
        if let retargetWindow {
            retargetWindow(BackendID(id))
            return
        }
        hasEverConnected = false
        isDisconnected = false
        connection.disconnect()
        resetWorkspaceStore()
        selectedWorkspaceId = nil
        pairingShowsSavedConnections = false
        connectionAttemptId += 1
        currentScreen = .connecting
    }

    /// Delete a saved connection. Any window on the deleted backend —
    /// including this one — leaves it via the registry's removal mark
    /// (window model v2: the window root closes the window, or rebinds a
    /// last remaining window to the pairing surface).
    func onDeleteConnection(id: UUID) {
        let wasThisWindows = windowConnectionID == id
        persistence.deleteConnection(id: id)
        persistence.clearLastScreen(for: id)
        sessionRegistry.markBackendRemoved(BackendID(id))
        if wasThisWindows {
            exitRemovedBackend()
        } else if persistence.loadConnections().isEmpty {
            pairingShowsSavedConnections = false
        }
    }

    func onOpenSettings() {
        currentScreen = .settings
    }

    /// Log Off forgets this window's backend only. Every window on the
    /// forgotten backend leaves it via the registry's removal mark (the
    /// window root closes it, or rebinds a last remaining window to the
    /// pairing surface, offering any remaining saved connections).
    func onLogOff() {
        if let record = windowConnection {
            persistence.deleteConnection(id: record.id)
            persistence.clearLastScreen(for: record.id)
            sessionRegistry.markBackendRemoved(BackendID(record.id))
        }
        exitRemovedBackend()
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
        if let connectionID = windowConnectionID {
            persistence.clearLastScreen(for: connectionID)
        }
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
    }

    func onBackToWorkspaceList() {
        selectedWorkspaceId = nil
        currentScreen = .workspaceList
        guard restoresLastScreen, let connectionID = windowConnectionID else { return }
        persistence.saveLastScreen(
            PersistenceManager.SavedScreen(
                screen: "workspaceList", workspaceId: nil,
                agentId: nil, agentName: nil, noteId: nil, noteTitle: nil),
            for: connectionID)
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
        // Windows without the restoration claim must not overwrite the
        // restoring window's saved navigation (spec decision 1b).
        guard restoresLastScreen else { return }
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
        guard let connectionID = windowConnectionID else { return }
        persistence.saveLastScreen(saved, for: connectionID)
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

