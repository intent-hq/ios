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

/// A pairing request delivered via an `intent://pair` deep link, awaiting
/// explicit user confirmation before any connection is attempted — unlike the
/// in-app camera scan, a deep link can be triggered by any web page.
struct DeepLinkPairingRequest: Identifiable, Equatable {
    let id = UUID()
    let payload: PairingPayload
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

final class AppCoordinatorLifecycleState {
    var hasEnteredRemoteUI = false
    var hasCompletedInitialRouting = false
    var workspaceDataAtInitialFlowStart: Date?
    var hasReturnedToSavedMachines = false
}

@MainActor
@Observable
class AppCoordinator {
    var currentScreen: AppScreen = .loading {
        didSet {
            navigationState.recentWorkspaceAgentRequestId = nil
            if !currentScreen.supportsConnectionLossOverlay {
                resetConnectionLossEligibility()
            }
        }
    }
    var selectedSection: AppSection = .workspaces {
        didSet {
            if selectedSection != oldValue { navigationState.recentWorkspaceAgentRequestId = nil }
        }
    }
    var assistantAgentId: String?
    private(set) var connectionFailureRetryPolicy: ConnectionFailureRetryPolicy = .automaticConnection
    var isDisconnected = false {
        didSet {
            if oldValue, !isDisconnected { connectionLossPresentation.recovered() }
        }
    }
    var showsConnectionLossOverlay: Bool {
        currentScreen.supportsConnectionLossOverlay && isDisconnected && !connectionLossPresentation.isDeferred
    }
    /// True when the pairing surface should also offer the remaining saved
    /// connections (e.g. after logging off the active connection while others
    /// are still saved). The Connect to… screen reads this flag.
    var pairingShowsSavedConnections = false
    /// True when the saved-connections store exists but could not be decoded.
    var savedConnectionsUndecodable = false
    /// Settings' snapshot, refreshed after the existing local/iCloud merge.
    var savedConnections: [StoredConnection] = []
    /// Deep-link pairing awaiting user confirmation; drives the
    /// DeepLinkPairingView sheet in RootView.
    var pendingDeepLinkPairing: DeepLinkPairingRequest?
    /// Keys ConnectingView's one-shot connection-attempt task. Bumped by
    /// onSwitchConnection so a switch performed while currentScreen is
    /// already .connecting (e.g. a deep-link pairing confirmed over the
    /// cold-start connect) restarts the attempt — SwiftUI would otherwise
    /// keep the existing ConnectingView and never re-run its task.
    private(set) var connectionAttemptId = 0
    /// Only launch/restoration auto-connect hides Connecting's Back action.
    var connectingStartedByLaunch = false
    var conversationRequestId = 0

    var selectedWorkspaceId: String? {
        didSet {
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
    @ObservationIgnored private var reconnectLoadingObservationID: UUID?
    /// Intentionally tracked so mutating it consumes the current one-shot
    /// workspace-loading registration before that registration is abandoned.
    private var reconnectLoadingObservationGeneration = 0
    @ObservationIgnored private var reconnectOverlayTimeoutTask: Task<Void, Never>?
    @ObservationIgnored var invitedRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var savedConnectionsObserver: AnyCancellable?

    @ObservationIgnored let dependencies: AppCoordinatorDependencies
    @ObservationIgnored let lifecycleState = AppCoordinatorLifecycleState()
    @ObservationIgnored let routingState = AppCoordinatorRoutingState()
    @ObservationIgnored let navigationState = AppCoordinatorNavigationState()
    @ObservationIgnored let connectionLossPresentation: ConnectionLossPresentation
    var canCreateWorkspace: Bool {
        dependencies.connection.connectionState == .connected && dependencies.connection.currentPrincipal?.canManageWorkspaces == true
    }

    /// Temporary transport recovery keeps the draft while submission remains
    /// gated. An authority invalidation, demotion, or final disconnect closes it.
    var shouldDismissWorkspaceCreation: Bool {
        if case .reconnecting = dependencies.connection.connectionState { return false }
        return dependencies.connection.currentPrincipal?.canManageWorkspaces != true
    }

    var canUseAssistant: Bool {
        dependencies.connection.connectionState == .connected && dependencies.connection.currentPrincipal?.isOwner == true
    }

    /// The backend this coordinator's window is bound to; nil only for a
    /// window that has no backend yet (pairing session). Bound windows route
    /// straight to .connecting on load and dial this backend's saved record.
    @ObservationIgnored let backendID: BackendID?
    /// Rebinds this coordinator's window to another backend, set by the
    /// window root (BackendWindowRoot). On single-window platforms it
    /// retargets the window in place; where multiple windows are supported
    /// it opens/raises the target backend's window instead (window model
    /// v2: a bound multi-window scene never retargets). When unset (tests,
    /// previews), switch/pair actions fall back to in-place routing over
    /// this session's connection.
    @ObservationIgnored var retargetWindow: ((BackendID) -> Void)?
    /// Detaches only this window and supplies a fresh pairing session. The
    /// root, not the coordinator, owns the registry's attachment count.
    @ObservationIgnored var returnWindowToSavedMachines: (() -> Void)?

    var agentDetails: AgentDetailStore

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
        claimScreenRestoration: @escaping @MainActor () -> Bool = { true }
    ) {
        agentDetails = AgentDetailStore(connection: connection)
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
        self.connectionLossPresentation = connectionLossPresentation
        lifecycleState.workspaceDataAtInitialFlowStart = workspaceStore.lastUpdated
        savedConnectionsObserver = persistence.connectionsDidChange.sink { [weak self] _ in
            self?.refreshSavedConnectionsPresentation()
        }
        startObservingConnection()
        startObservingCertMismatch()
        startObservingWorkspaceList()
    }

    /// Restarts the keyed ConnectingView task while preserving its transition order.
    func restartConnectionAttempt() {
        connectingStartedByLaunch = false
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
        reconnectOverlayTimeoutTask?.cancel()
        cancelReconnectLoadingObservation()
    }
}

extension AppCoordinator {
    /// A timed-out initial data wait still uses the normal navigation fallback,
    /// but cannot arm the blocking overlay. Require data fetched in this flow.
    func establishConnectionLossEligibility() {
        guard !lifecycleState.hasEnteredRemoteUI,
              lifecycleState.hasCompletedInitialRouting,
              currentScreen.supportsConnectionLossOverlay,
              dependencies.connection.connectionState == .connected,
              let lastUpdated = dependencies.workspaceStore.lastUpdated,
              lastUpdated != lifecycleState.workspaceDataAtInitialFlowStart else { return }
        lifecycleState.hasEnteredRemoteUI = true
        // Retire only deliveries queued before entry became usable.
        startObservingConnection()
    }

    /// A new initial flow must not inherit a previous session's loss or delayed recovery work.
    func resetConnectionLossEligibility() {
        connectionLossPresentation.reset()
        lifecycleState.hasEnteredRemoteUI = false
        lifecycleState.hasCompletedInitialRouting = false
        lifecycleState.workspaceDataAtInitialFlowStart = dependencies.workspaceStore.lastUpdated
        isDisconnected = false
        cancelReconnectLoadingObservation()
        reconnectOverlayTimeoutTask?.cancel()
        reconnectOverlayTimeoutTask = nil
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
                    cancelReconnectLoadingObservation()
                    reconnectOverlayTimeoutTask?.cancel()
                    reconnectOverlayTimeoutTask = nil
                    if lifecycleState.hasEnteredRemoteUI, currentScreen.supportsConnectionLossOverlay {
                        isDisconnected = true
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
        guard isDisconnected, dependencies.connection.connectionState == .connected,
              reconnectLoadingObservationID == nil else { return }
        waitForWorkspaceLoadThenClearOverlay()
        revalidateCurrentAgentAfterReconnect()
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
        if !dependencies.workspaceStore.isLoading, dependencies.workspaceStore.lastUpdated != nil {
            isDisconnected = false
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
            guard let self, !Task.isCancelled, dependencies.connection.connectionState == .connected else { return }
            reconnectOverlayTimeoutTask = nil
            if isDisconnected {
                cancelReconnectLoadingObservation()
                isDisconnected = false
            }
        }
    }

    private func cancelReconnectLoadingObservation() {
        guard reconnectLoadingObservationID != nil else { return }
        reconnectLoadingObservationID = nil
        reconnectLoadingObservationGeneration &+= 1
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
                      reconnectLoadingObservationID == observationID,
                      dependencies.connection.connectionState == .connected else { return }
                if dependencies.workspaceStore.isLoading {
                    observeWorkspaceLoading(observationID: observationID)
                } else {
                    reconnectOverlayTimeoutTask?.cancel()
                    reconnectOverlayTimeoutTask = nil
                    cancelReconnectLoadingObservation()
                    isDisconnected = false
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

        // Check if workspace is archived or deleted
        let status = workspace.status?.lowercased() ?? ""
        if status == "archived" || status == "deleted" {
            handleMissingWorkspace()
        }
    }
}
