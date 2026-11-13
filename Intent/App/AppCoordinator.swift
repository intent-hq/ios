import Combine
import Observation
import SwiftUI

enum AppScreen {
    case agentConversation(agentId: String, workspaceId: String, agentName: String)
    case connecting
    case connectionFailed(error: String)
    case disconnected
    case loading
    case noteDetail(noteId: String, workspaceId: String, noteTitle: String)
    case pairing
    case settings
    case workspaceDetail(workspaceId: String)
    case workspaceList

    var supportsConnectionLossOverlay: Bool {
        switch self {
        case .workspaceList, .workspaceDetail, .agentConversation, .noteDetail, .settings:
            return true
        case .loading, .connecting, .pairing, .connectionFailed, .disconnected:
            return false
        }
    }
}

enum AppSection: Hashable {
    case assistant
    case workspaces
}

enum ConnectionFailureRetryPolicy: Equatable {
    case automaticConnection
    case manualLogOff
}

struct AppCoordinatorDependencies {
    let workspaceStore: WorkspaceStore
    let connection: any SessionConnectionManaging
    let persistence: PersistenceManager
    let sessionRegistry: BackendSessionRegistry
    let syncedRegistry: SyncedBackendRegistry
    let backgroundTaskManager: BackgroundTaskManager
    let reconnectLoadingObservationDidChange: @Sendable () -> Void
    let claimScreenRestoration: @MainActor () -> Bool
}

@MainActor
@Observable
class AppCoordinator {
    var currentScreen: AppScreen = .loading {
        didSet {
            workspaceChange = nil
            navigationState.recentWorkspaceAgentRequestId = nil
            recordAgentVisit()
            let connectionScreen = connectionScreen.kept(on: currentScreen)
            if connectionScreen != self.connectionScreen { self.connectionScreen = connectionScreen }
            if !currentScreen.supportsConnectionLossOverlay {
                resetConnectionLossEligibility()
            }
        }
    }
    var selectedSection: AppSection = .workspaces {
        didSet {
            if selectedSection != oldValue { navigationState.recentWorkspaceAgentRequestId = nil }
            if usesIPadShell, selectedSection == .workspaces, oldValue == .assistant {
                iPadNavigation.showWorkspaceDetail()
            }
        }
    }
    var usesIPadShell = false
    var iPadNavigation = IPadNavigationState()
    /// The window's workspace list settings, reported by its iPad sidebar.
    var workspaceListPresentation = WorkspaceListPresentation()
    var workspaceChange: WorkspaceChangeDestination?
    /// The pull request in the iPad main pane.
    var iPadPullRequest: PullRequestListItem?
    var workspaceSidebarAgents = WorkspaceSidebarAgents()
    var assistantAgentId: String?
    var workspaceCreationDraft: WorkspaceCreationDraft?
    private(set) var connectionFailureRetryPolicy: ConnectionFailureRetryPolicy = .automaticConnection
    /// Set only by the connection observer and recovery; leaving it clears the
    /// recovery's workspace-load observation and timeout.
    var connectionLoss = ConnectionLoss.none {
        didSet {
            endRecoveryWait(oldValue)
            if oldValue.isLost, !connectionLoss.isLost { connectionLossPresentation.recovered() }
        }
    }
    /// A loss recorded after entry that has not finished recovering. Unlike
    /// the transport state, it stays true while reconnected data reloads.
    var isDisconnected: Bool { connectionLoss.isLost }
    /// The loading/connecting splash and Connect to… screen state.
    var connectionScreen: ConnectionScreen
    /// The Connect to… screen also offers the remaining saved connections.
    var pairingShowsSavedConnections: Bool {
        if case .pairing(let shows) = connectionScreen { return shows }
        return false
    }
    /// True when the saved-connections store exists but could not be decoded.
    var savedConnectionsUndecodable = false
    /// Settings' snapshot, refreshed after the existing local/iCloud merge.
    var savedConnections: [StoredConnection] = []
    /// Deep link awaiting user confirmation; drives the DeepLinkPairingView
    /// or InviteJoinView sheet in RootView.
    var pendingDeepLink: DeepLinkRequest?
    /// Keys ConnectingView's one-shot connection-attempt task. Bumped by
    /// onSwitchConnection so a switch performed while currentScreen is
    /// already .connecting (e.g. a deep-link pairing confirmed over the
    /// cold-start connect) restarts the attempt — SwiftUI would otherwise
    /// keep the existing ConnectingView and never re-run its task.
    private(set) var connectionAttemptId = 0
    /// Only launch/restoration auto-connect hides Connecting's Back action.
    var connectingStartedByLaunch: Bool {
        connectionScreen == .connecting(startedByLaunch: true)
    }
    var conversationRequestId = 0

    var selectedWorkspaceId: String? {
        didSet {
            if selectedWorkspaceId != oldValue { iPadNavigation.closeTool() }
            if selectedWorkspaceId != oldValue { navigationState.recentWorkspaceAgentRequestId = nil }
            if let workspaceId = selectedWorkspaceId,
               selectedWorkspaceId != oldValue,
               !navigationState.suppressWorkspaceNavigation {
                currentScreen = .workspaceDetail(workspaceId: workspaceId)
            }
        }
    }
    var currentScreenDescription: String {
        String(describing: currentScreen)
    }

    @ObservationIgnored private var connectionObserver: AnyCancellable?
    @ObservationIgnored private var connectionObservationID: UUID?
    @ObservationIgnored private var certMismatchObserver: AnyCancellable?
    /// Intentionally tracked so mutating it consumes the current one-shot
    /// workspace-loading registration before that registration is abandoned.
    private var reconnectLoadingObservationGeneration = 0
    @ObservationIgnored var invitedRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var savedConnectionsObserver: AnyCancellable?
    @ObservationIgnored private var workspaceRemovalObserver: AnyCancellable?

    @ObservationIgnored let dependencies: AppCoordinatorDependencies
    @ObservationIgnored let lifecycleState = AppCoordinatorLifecycleState()
    @ObservationIgnored let routingState = AppCoordinatorRoutingState()
    @ObservationIgnored let navigationState = AppCoordinatorNavigationState()
    @ObservationIgnored let connectionLossPresentation: ConnectionLossPresentation
    /// This window's recently viewed workspace pages, readable during a drop.
    @ObservationIgnored let workspaceDetailStores = WorkspaceDetailStoresCache()
    var canCreateWorkspace: Bool {
        dependencies.connection.connectionState == .connected && !isRemoteReadOnly
            && dependencies.connection.currentPrincipal?.canManageWorkspaces == true
    }

    func makeWorkspaceCreationDraft() -> WorkspaceCreationDraft {
        workspaceCreationDraft ?? makeFreshWorkspaceCreationDraft()
    }

    func makeFreshWorkspaceCreationDraft() -> WorkspaceCreationDraft {
        WorkspaceCreationDraft(backendID: backendID, persistence: dependencies.persistence)
    }

    /// A fresh prefilled draft; the saved ordinary draft stays untouched.
    func makeWorkspaceCreationDraft(for pullRequest: PullRequestListItem) -> WorkspaceCreationDraft {
        var draft = makeFreshWorkspaceCreationDraft()
        draft.prefill(pullRequest: pullRequest)
        return draft
    }

    /// Temporary transport recovery keeps the draft while submission remains
    /// gated. An authority invalidation, demotion, or final disconnect closes it.
    var shouldDismissWorkspaceCreation: Bool {
        if case .reconnecting = dependencies.connection.connectionState { return false }
        return dependencies.connection.currentPrincipal?.canManageWorkspaces != true
    }

    var canUseAssistant: Bool {
        // A drop clears the live principal, so read-only navigation falls back to
        // the person last confirmed. Mutation checks keep using the live one.
        let connection = dependencies.connection
        if connection.connectionState == .connected { return connection.currentPrincipal?.isOwner == true }
        return remotePhase == .readOnly && (connection.currentPrincipal ?? connection.lastConnectedPrincipal)?.isOwner == true
    }

    /// The backend this coordinator's window is bound to; nil only for a
    /// window that has no backend yet (pairing session). Bound windows route
    /// straight to .connecting on load and dial this backend's saved record.
    @ObservationIgnored let backendID: BackendID?
    /// Rebinds this coordinator's window to another backend in place, set
    /// by the window root (BackendWindowRoot); an unbound pairing window is
    /// replaced by the target's own window instead. When unset (tests,
    /// previews), switch/pair actions fall back to in-place routing over
    /// this session's connection.
    @ObservationIgnored var retargetWindow: ((BackendID) -> Void)?
    /// Hands a hijacked shared connection's re-dial to a window that stays
    /// on this backend, set by the session. When unset, this window re-dials.
    @ObservationIgnored var repairSharedConnection: (() -> Void)?
    /// Detaches only this window and supplies a fresh pairing session. The
    /// root, not the coordinator, owns the registry's attachment count.
    @ObservationIgnored var returnWindowToSavedMachines: (() -> Void)?

    var agentDetails: AgentDetailStore
    /// Shared across windows and backends; tests get one over their own persistence.
    @ObservationIgnored let agentHistory: AgentHistoryStore

    init(
        workspaceStore: WorkspaceStore,
        connection: any SessionConnectionManaging,
        backendID: BackendID? = nil,
        persistence: PersistenceManager = PersistenceManager.shared,
        sessionRegistry: BackendSessionRegistry = .shared,
        syncedRegistry: SyncedBackendRegistry = SyncedBackendRegistry(),
        backgroundTaskManager: BackgroundTaskManager = BackgroundTaskManager(),
        connectionLossPresentation: ConnectionLossPresentation = ConnectionLossPresentation(),
        reconnectLoadingObservationDidChange: @escaping @Sendable () -> Void = {},
        claimScreenRestoration: @escaping @MainActor () -> Bool = { true },
        agentHistory: AgentHistoryStore? = nil
    ) {
        agentDetails = AgentDetailStore(connection: connection)
        self.agentHistory = agentHistory ?? AgentHistoryStore(persistence: persistence)
        dependencies = AppCoordinatorDependencies(
            workspaceStore: workspaceStore,
            connection: connection,
            persistence: persistence,
            sessionRegistry: sessionRegistry,
            syncedRegistry: syncedRegistry,
            backgroundTaskManager: backgroundTaskManager,
            reconnectLoadingObservationDidChange: reconnectLoadingObservationDidChange,
            claimScreenRestoration: claimScreenRestoration
        )
        self.backendID = backendID
        connectionScreen = .connecting(startedByLaunch: !sessionRegistry.consumeConnectionSelection(for: backendID))
        self.connectionLossPresentation = connectionLossPresentation
        workspaceListPresentation = WorkspaceListPresentation(persistence: persistence)
        lifecycleState.entry = .routing(dataStamp: workspaceStore.lastUpdated)
        savedConnectionsObserver = persistence.connectionsDidChange.sink { [weak self] _ in
            self?.refreshSavedConnectionsPresentation()
        }
        workspaceRemovalObserver = workspaceStore.removedWorkspaceIds.sink { [weak self] workspaceId in
            self?.forgetHistory(ofWorkspace: workspaceId)
        }
        startObservingConnection()
        startObservingCertMismatch()
        startObservingWorkspaceList()
        startObservingIPadAutoSelection()
    }

    /// Restarts the keyed ConnectingView task while preserving its transition order.
    func restartConnectionAttempt() {
        connectionScreen = .connecting(startedByLaunch: false)
        connectionAttemptId += 1
        currentScreen = .connecting
    }

    /// Applies retry ownership before exposing the corresponding failure screen.
    func routeToConnectionFailure(error: String, retryPolicy: ConnectionFailureRetryPolicy) {
        guard !lifecycleState.hasReturnedToSavedMachines else { return }
        connectionFailureRetryPolicy = retryPolicy
        currentScreen = .connectionFailed(error: error)
    }

    isolated deinit {
        invitedRefreshTask?.cancel()
        connectionLossPresentation.reset()
        endRecoveryWait(connectionLoss)
    }

    /// Cancels a recovery's timeout and retires its one-shot workspace-loading
    /// registration. Every write that leaves `.recovering` goes through here.
    private func endRecoveryWait(_ loss: ConnectionLoss) {
        guard case .recovering(_, let timeout) = loss else { return }
        timeout.cancel()
        reconnectLoadingObservationGeneration &+= 1
    }
}

extension AppCoordinator {
    /// A timed-out initial data wait still uses the normal navigation fallback,
    /// but cannot arm the blocking overlay. Require data fetched in this flow.
    func establishConnectionLossEligibility() {
        guard case .routed(let dataStamp) = lifecycleState.entry,
              currentScreen.supportsConnectionLossOverlay,
              dependencies.connection.connectionState == .connected,
              let lastUpdated = dependencies.workspaceStore.lastUpdated,
              lastUpdated != dataStamp else { return }
        lifecycleState.entry = .entered
        // Retire only deliveries queued before entry became usable.
        startObservingConnection()
    }

    /// A new initial flow must not inherit a previous session's loss or delayed recovery work.
    func resetConnectionLossEligibility() {
        // Leaving the remote UI (Home, Log Off, switching Mac) drops retained pages.
        workspaceDetailStores.removeAll()
        connectionLossPresentation.reset()
        lifecycleState.entry = .routing(dataStamp: dependencies.workspaceStore.lastUpdated)
        connectionLoss = .none
    }

    /// Retire callbacks before the root releases the session: queued publisher
    /// deliveries and old ConnectingView completions must not leave Home.
    func stopConnectionLifecycleForReturnHome() {
        lifecycleState.hasReturnedToSavedMachines = true
        resetConnectionLossEligibility()
        connectionObserver = nil
        certMismatchObserver = nil
        dependencies.backgroundTaskManager.endIfNeeded()
    }

    /// Standalone coordinators (tests/previews) reuse their connection on an
    /// explicit saved-machine selection; the live root creates a new one.
    func resumeConnectionLifecycleIfNeeded() {
        guard lifecycleState.hasReturnedToSavedMachines else { return }
        lifecycleState.hasReturnedToSavedMachines = false
        startObservingConnection()
        startObservingCertMismatch()
    }

    private func startObservingConnection() {
        let observationID = UUID()
        connectionObservationID = observationID
        connectionObserver = dependencies.connection.connectionStatePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, !lifecycleState.hasReturnedToSavedMachines,
                      connectionObservationID == observationID,
                      connectionDeliveryIsCurrent(state) else { return }
                switch state {
                case .reconnecting, .disconnected:
                    // A recovery in progress stops waiting and shows the loss again.
                    if connectionLoss.isLost
                        || (lifecycleState.hasEnteredRemoteUI && currentScreen.supportsConnectionLossOverlay) {
                        connectionLoss = .lost
                    }
                case .connected:
                    establishConnectionLossEligibility()
                    let wasDisconnected = isDisconnected
                    if wasDisconnected {
                        // On reconnection, wait for workspace data to load before
                        // clearing the overlay so the UI doesn't flash blank metadata.
                        waitForWorkspaceLoadThenClearOverlay()
                        // The agent shown in an open conversation may have been
                        // deleted while disconnected — re-validate it. (Workspace
                        // validation follows from the reconnect fetchAll.)
                        revalidateCurrentAgentAfterReconnect()
                    } else {
                        // Initial connection — isDisconnected was never true, nothing to clear.
                    }
                default:
                    break
                }
            }
    }

    private func connectionDeliveryIsCurrent(_ state: ConnectionState) -> Bool {
        guard state != dependencies.connection.connectionState else { return true }
        // A loss/recovery burst can finish before either publisher delivery.
        // Never present its obsolete loss, but keep the reconnect's agent check.
        if lifecycleState.hasEnteredRemoteUI, dependencies.connection.connectionState == .connected {
            switch state {
            case .disconnected, .reconnecting: revalidateCurrentAgentAfterReconnect()
            default: break
            }
        }
        return false
    }

    func reconcileBackgroundRecovery() {
        guard case .lost = connectionLoss, dependencies.connection.connectionState == .connected else { return }
        waitForWorkspaceLoadThenClearOverlay()
        revalidateCurrentAgentAfterReconnect()
    }

    /// Wait for WorkspaceStore to finish loading before clearing the reconnection overlay.
    /// Falls back to a 5-second timeout so the overlay never gets stuck.
    private func waitForWorkspaceLoadThenClearOverlay() {
        // Cancel any previous observer from a prior reconnection attempt
        connectionLoss = .lost

        // If WorkspaceStore is not currently loading (fetchAll already completed
        // or hasn't started yet), check if data is already available.
        if !dependencies.workspaceStore.isLoading, dependencies.workspaceStore.lastUpdated != nil {
            connectionLoss = .none
            return
        }

        // Observe isLoading: wait for it to go from true → false (fetchAll completed).
        let observationID = UUID()
        // Timeout: if the fetch takes too long or fails silently, clear the overlay anyway.
        let timeout = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Constants.AppCoordination.reconnectOverlayTimeout)
            } catch {
                return
            }
            guard let self, !Task.isCancelled, dependencies.connection.connectionState == .connected else { return }
            connectionLoss = .none
        }
        connectionLoss = .recovering(observationID: observationID, timeout: timeout)
        observeWorkspaceLoading(observationID: observationID)
    }

    private func observeWorkspaceLoading(observationID: UUID) {
        let observationDidChange = dependencies.reconnectLoadingObservationDidChange
        withObservationTracking {
            _ = dependencies.workspaceStore.isLoading
            _ = reconnectLoadingObservationGeneration
        } onChange: { [weak self] in
            observationDidChange()
            Task { @MainActor [weak self] in
                guard let self,
                      case .recovering(observationID, _) = connectionLoss,
                      dependencies.connection.connectionState == .connected else { return }
                if dependencies.workspaceStore.isLoading {
                    observeWorkspaceLoading(observationID: observationID)
                } else {
                    connectionLoss = .none
                }
            }
        }
    }

    private func startObservingCertMismatch() {
        certMismatchObserver = dependencies.connection.certMismatchPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] mismatch in
                guard let self, !lifecycleState.hasReturnedToSavedMachines, mismatch else { return }
                routeToConnectionFailure(
                    error: "Server certificate has changed. Please re-pair your device.",
                    retryPolicy: .automaticConnection
                )
                // Reset the flag so it doesn't re-trigger
                dependencies.connection.certMismatchDetected = false
            }
    }

    private func startObservingWorkspaceList() {
        withObservationTracking {
            _ = dependencies.workspaceStore.lastUpdated
            _ = dependencies.workspaceStore.workspaces
            _ = dependencies.workspaceStore.showArchived
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                startObservingWorkspaceList()
                guard !lifecycleState.hasReturnedToSavedMachines else { return }
                establishConnectionLossEligibility()
                // Only validate after workspaces have been fetched at least once
                guard dependencies.workspaceStore.lastUpdated != nil else { return }
                validateCurrentWorkspaceExists(in: dependencies.workspaceStore.workspaces)
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
            handleMissingWorkspace()
            return
        }

        let status = workspace.status?.lowercased() ?? ""
        if status == "deleted" || (status == "archived" && !dependencies.workspaceStore.showArchived) {
            handleMissingWorkspace()
        }
    }
}
