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
    var workspaceListPresentation = WorkspaceListPresentation()
    var workspaceChange: WorkspaceChangeDestination?
    var iPadPullRequest: PullRequestListItem?
    var workspaceSidebarAgents = WorkspaceSidebarAgents()
    var assistantAgentId: String?
    var workspaceCreationDraft: WorkspaceCreationDraft?
    private(set) var connectionFailureRetryPolicy: ConnectionFailureRetryPolicy = .automaticConnection
    var connectionLoss = ConnectionLoss.none {
        didSet {
            endRecoveryWait(oldValue)
            if oldValue.isLost, !connectionLoss.isLost { connectionLossPresentation.recovered() }
        }
    }
    var isDisconnected: Bool { connectionLoss.isLost }
    var connectionScreen: ConnectionScreen
    var pairingShowsSavedConnections: Bool {
        if case .pairing(let shows) = connectionScreen { return shows }
        return false
    }
    var savedConnectionsUndecodable = false
    var savedConnections: [StoredConnection] = []
    var pendingDeepLink: DeepLinkRequest?
    private(set) var connectionAttemptId = 0
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
    private var reconnectLoadingObservationGeneration = 0
    @ObservationIgnored var invitedRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var savedConnectionsObserver: AnyCancellable?
    @ObservationIgnored private var workspaceRemovalObserver: AnyCancellable?

    @ObservationIgnored let dependencies: AppCoordinatorDependencies
    @ObservationIgnored let lifecycleState = AppCoordinatorLifecycleState()
    @ObservationIgnored let routingState = AppCoordinatorRoutingState()
    @ObservationIgnored let navigationState = AppCoordinatorNavigationState()
    @ObservationIgnored let connectionLossPresentation: ConnectionLossPresentation
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

    func makeWorkspaceCreationDraft(for pullRequest: PullRequestListItem) -> WorkspaceCreationDraft {
        var draft = makeFreshWorkspaceCreationDraft()
        draft.prefill(pullRequest: pullRequest)
        return draft
    }

    var shouldDismissWorkspaceCreation: Bool {
        if case .reconnecting = dependencies.connection.connectionState { return false }
        return dependencies.connection.currentPrincipal?.canManageWorkspaces != true
    }

    var canUseAssistant: Bool {
        let connection = dependencies.connection
        if connection.connectionState == .connected { return connection.currentPrincipal?.isOwner == true }
        return remotePhase == .readOnly && (connection.currentPrincipal ?? connection.lastConnectedPrincipal)?.isOwner == true
    }

    @ObservationIgnored let backendID: BackendID?
    @ObservationIgnored var retargetWindow: ((BackendID) -> Void)?
    @ObservationIgnored var retargetRoute: ((BackendID) -> WindowRetargetRoute)?

    var choosesBackendInPlace: Bool {
        !currentScreen.supportsConnectionLossOverlay
    }
    @ObservationIgnored var repairSharedConnection: (() -> Void)?
    @ObservationIgnored var returnWindowToSavedMachines: (() -> Void)?

    var agentDetails: AgentDetailStore
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

    func restartConnectionAttempt() {
        connectionScreen = .connecting(startedByLaunch: false)
        connectionAttemptId += 1
        currentScreen = .connecting
    }

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

    private func endRecoveryWait(_ loss: ConnectionLoss) {
        guard case .recovering(_, let timeout) = loss else { return }
        timeout.cancel()
        reconnectLoadingObservationGeneration &+= 1
    }
}

extension AppCoordinator {
    func establishConnectionLossEligibility() {
        guard case .routed(let dataStamp) = lifecycleState.entry,
              currentScreen.supportsConnectionLossOverlay,
              dependencies.connection.connectionState == .connected,
              let lastUpdated = dependencies.workspaceStore.lastUpdated,
              lastUpdated != dataStamp else { return }
        lifecycleState.entry = .entered
        startObservingConnection()
    }

    func resetConnectionLossEligibility() {
        workspaceDetailStores.removeAll()
        connectionLossPresentation.reset()
        lifecycleState.entry = .routing(dataStamp: dependencies.workspaceStore.lastUpdated)
        connectionLoss = .none
    }

    func stopConnectionLifecycleForReturnHome() {
        lifecycleState.hasReturnedToSavedMachines = true
        resetConnectionLossEligibility()
        connectionObserver = nil
        certMismatchObserver = nil
        dependencies.backgroundTaskManager.endIfNeeded()
    }

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
                    if connectionLoss.isLost
                        || (lifecycleState.hasEnteredRemoteUI && currentScreen.supportsConnectionLossOverlay) {
                        connectionLoss = .lost
                    }
                case .connected:
                    establishConnectionLossEligibility()
                    let wasDisconnected = isDisconnected
                    if wasDisconnected {
                        waitForWorkspaceLoadThenClearOverlay()
                        revalidateCurrentAgentAfterReconnect()
                    } else {
                    }
                default:
                    break
                }
            }
    }

    private func connectionDeliveryIsCurrent(_ state: ConnectionState) -> Bool {
        guard state != dependencies.connection.connectionState else { return true }
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

    private func waitForWorkspaceLoadThenClearOverlay() {
        connectionLoss = .lost

        if !dependencies.workspaceStore.isLoading, dependencies.workspaceStore.lastUpdated != nil {
            connectionLoss = .none
            return
        }

        let observationID = UUID()
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
                guard dependencies.workspaceStore.lastUpdated != nil else { return }
                validateCurrentWorkspaceExists(in: dependencies.workspaceStore.workspaces)
            }
        }
    }

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
