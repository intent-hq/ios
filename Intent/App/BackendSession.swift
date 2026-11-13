import Combine
import Foundation
import Observation

/// The connection surface a `BackendSession` owns: the routing seam the
/// stores already depend on, plus the lifecycle, credential and certificate
/// surfaces the coordinator and the connection views drive on their own
/// session instead of a process-wide singleton.
/// `ConnectionManager` conforms as-is; tests inject fakes.
@MainActor
protocol SessionConnectionManaging: ConnectionManagerRouting {
    /// Settable so demo mode can mark the session connected without a socket.
    var connectionState: ConnectionState { get set }
    /// Per-host certificate mismatches observed by the current race.
    var certMismatches: [HostCertMismatch] { get }
    var startupState: DaemonStartupState? { get }
    /// Raised when a pinned certificate changed; the coordinator clears it
    /// once it has routed to the failure screen.
    var certMismatchDetected: Bool { get set }
    var certMismatchPublisher: AnyPublisher<Bool, Never> { get }
    /// Dialer used to probe a server certificate over a Tailcat tunnel.
    var tunnelDialer: any TunnelDialing { get }
    /// Where the live socket's global event subscription stands; `.failed`
    /// once its bounded retries are exhausted, which the window surfaces
    /// with a retry action routed to `retryGlobalSubscription()` (ios#254).
    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState { get }
    /// Why automatic reconnection stopped for good; nil while it may recover.
    var reconnectStopReason: String? { get }

    var currentPrincipal: ConnectionPrincipal? { get }
    /// The person last confirmed on a live connection, kept through a drop that
    /// keeps reconnecting. For read-only navigation only, never for authority.
    var lastConnectedPrincipal: ConnectionPrincipal? { get }
    var admission: ConnectionAdmission? { get }
    var pairingAttemptID: UUID? { get }

    func confirmedPrincipal() async throws -> ConnectionPrincipal

    func retryGlobalSubscription()
    func makeBrowserProxy() async throws -> any BrowserProxySession

    func connect(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    ) async throws
    func updateCachedCredentials(
        hosts: [String],
        port: Int,
        token: String,
        certFingerprint: String?,
        tcAddress: String?
    )
    func refreshHostRoutes() async
    #if DEBUG
    /// Debug-only: Release callers fail to compile.
    func connectDemo(serveFixtures: Bool)
    #endif
    func disconnect()
}

extension SessionConnectionManaging {
    var startupState: DaemonStartupState? { nil }
    var lastConnectedPrincipal: ConnectionPrincipal? { nil }
    var reconnectStopReason: String? { nil }

    func makeBrowserProxy() throws -> any BrowserProxySession {
        throw BrowserTunnelError.unavailable
    }
}

extension ConnectionManager: SessionConnectionManaging {}

/// One backend's runtime state: the connection plus the per-window stores
/// and loaders from the spec's state split. Sessions are vended by
/// `BackendSessionRegistry`; this type never reads process-wide singletons —
/// the registry's live factory composes fresh per-backend instances (window
/// model v2: every window is bound to exactly one backend; there is no
/// default session).
@MainActor
@Observable
final class BackendSession {
    /// Builds a per-window coordinator bound to this session's connection and
    /// stores. `claimScreenRestoration` is the coordinator's lazy hook into
    /// `claimScreenRestoration()` below.
    typealias CoordinatorFactory =
        @MainActor (_ claimScreenRestoration: @escaping @MainActor () -> Bool) -> AppCoordinator

    /// The backend this session is bound to; nil only for the transient
    /// pairing session backing a window that has no backend yet (first run,
    /// or a window unbound after its backend was removed).
    let backendID: BackendID?
    let connection: any SessionConnectionManaging
    let workspaceStore: WorkspaceStore
    let assistantStore: AssistantStore
    /// Authoritative detail state shared by routes, conversations and proposal cards.
    let agentDetails: AgentDetailStore
    var agentSummaries: AgentSummaryStore { agentDetails.summaries }
    let conversations: ConversationStorePool
    /// Session-lifetime GitHub repo cache for the New Workspace repo step;
    /// outlives the sheet so a reopen renders the cached list instantly.
    let githubRepoStore: GitHubRepoStore
    /// Session-lifetime specialist / provider / model cache for the New
    /// Workspace final step; same reopen-instantly contract as the repo cache.
    let creationOptionsStore: CreationOptionsStore
    let hooksStore: WorkspaceStatusStore<BackgroundHook>
    let scriptMonitorsStore: WorkspaceScriptMonitorsStore
    let prMonitorsStore: WorkspacePrMonitorsStore
    let pullRequestListStore: PullRequestListStore
    let mobileTerminalStore: MobileTerminalStore
    let browserStore: WorkspaceBrowserStore
    let browserNavigation: NativeBrowserNavigation
    let attachmentUploadService: AttachmentUploadService
    let workspaceFileImageLoader: WorkspaceFileImageLoader
    let attachmentImageLoader: AttachmentImageLoader
    let attentionCueCenter: WorkspaceAttentionCueCenter

    private let coordinatorFactory: CoordinatorFactory
    private var screenRestorationClaimed = false
    @ObservationIgnored private var coordinators: [WeakCoordinator] = []

    init(
        backendID: BackendID?,
        connection: any SessionConnectionManaging,
        workspaceStore: WorkspaceStore,
        coordinatorFactory: @escaping CoordinatorFactory,
        githubRepoStore: GitHubRepoStore,
        creationOptionsStore: CreationOptionsStore,
        prMonitorsStore: WorkspacePrMonitorsStore,
        attachmentUploadService: AttachmentUploadService,
        workspaceFileImageLoader: WorkspaceFileImageLoader,
        attachmentImageLoader: AttachmentImageLoader,
        attentionCueCenter: WorkspaceAttentionCueCenter
    ) {
        self.backendID = backendID
        self.connection = connection
        self.workspaceStore = workspaceStore
        let details = AgentDetailStore(connection: connection)
        self.agentDetails = details
        workspaceStore.agentSummaries = details.summaries
        self.assistantStore = AssistantStore(connection: connection, summaries: details.summaries)
        self.conversations = ConversationStorePool(connection: connection, details: details)
        self.coordinatorFactory = coordinatorFactory
        self.githubRepoStore = githubRepoStore
        self.creationOptionsStore = creationOptionsStore
        self.hooksStore = BackgroundHookStore.makeWorkspaceStore(connection: connection)
        self.prMonitorsStore = prMonitorsStore
        self.scriptMonitorsStore = WorkspaceScriptMonitorsStore(connection: connection)
        pullRequestListStore = PullRequestListStore(connection: connection)
        mobileTerminalStore = MobileTerminalStore(
            connection: connection,
            persistence: MobileTerminalPersistence(backendID: backendID)
        )
        browserStore = WorkspaceBrowserStore(connection: connection, backendID: backendID)
        let navigation = NativeBrowserNavigation(connection: connection, backendID: backendID)
        browserNavigation = navigation
        browserStore.nativeNavigation = navigation
        self.attachmentUploadService = attachmentUploadService
        self.workspaceFileImageLoader = workspaceFileImageLoader
        self.attachmentImageLoader = attachmentImageLoader
        self.attentionCueCenter = attentionCueCenter
        navigation.savedBrowsers = { [weak browserStore] workspaceId in
            browserStore?.savedBrowsers(workspaceId: workspaceId) ?? []
        }
        if let manager = connection as? ConnectionManager {
            manager.browserNavigationHandler = { [weak navigation] params in
                guard let navigation else { return ["success": false, "error": "Native browser is unavailable."] }
                return await navigation.execute(params)
            }
        }
    }

    /// A fresh coordinator for one window over this session. Windows sharing
    /// the session share connection + stores but navigate independently
    /// (spec "State split"); the coordinator claims last-screen restoration
    /// lazily via `claimScreenRestoration()`.
    /// `startingAtSavedMachines` skips the launch splash after an explicit
    /// return Home, including in demo mode. No connection attempt is started.
    func makeCoordinator(startingAtSavedMachines: Bool = false) -> AppCoordinator {
        let coordinator = coordinatorFactory { [weak self] in
            self?.claimScreenRestoration() ?? false
        }
        coordinator.agentDetails = agentDetails
        coordinators.removeAll { $0.value == nil }
        coordinators.append(WeakCoordinator(value: coordinator))
        coordinator.repairSharedConnection = { [weak self, weak coordinator] in
            self?.repairConnection(leaving: coordinator)
        }
        if startingAtSavedMachines {
            coordinator.routingState.hasLoadCompleted = true
            coordinator.onReconnect()
        }
        return coordinator
    }

    /// A pairing from `leaving`'s window dialed another daemon over this
    /// session's shared connection, and that window is switching away. One
    /// window that stays on this backend re-dials it; with none left, the
    /// registry tears the session down when `leaving` detaches.
    func repairConnection(leaving: AppCoordinator?) {
        coordinators.removeAll { $0.value == nil }
        coordinators
            .compactMap(\.value)
            .first { $0 !== leaving && !$0.lifecycleState.hasReturnedToSavedMachines }?
            .redialWindowBackend()
    }

    /// Grants last-screen restoration to this session's first claimant only:
    /// the first window on a backend restores that backend's saved screen;
    /// duplicated windows start at the workspace list. Pairing sessions
    /// (nil backendID) have no backend to restore.
    func claimScreenRestoration() -> Bool {
        guard backendID != nil, !screenRestorationClaimed else { return false }
        screenRestorationClaimed = true
        return true
    }

    /// The window keeps these leases across conversation switches in its
    /// selected workspace. Conversation/row leases share the exact same caches.
    func retainWorkspaceStatus(workspaceId: String, consumer: UUID) {
        hooksStore.retain(workspaceId: workspaceId, consumer: consumer)
        prMonitorsStore.retain(workspaceId: workspaceId, consumer: consumer)
        Task {
            guard hooksStore.buckets[workspaceId]?.consumers.contains(consumer) == true else { return }
            async let hooks: () = hooksStore.load(workspaceId: workspaceId)
            async let monitors: () = prMonitorsStore.seed(workspaceId: workspaceId)
            _ = await (hooks, monitors)
        }
    }

    func releaseWorkspaceStatus(workspaceId: String, consumer: UUID) {
        hooksStore.release(workspaceId: workspaceId, consumer: consumer)
        prMonitorsStore.release(workspaceId: workspaceId, consumer: consumer)
    }

    /// Disconnects the backend connection. Called by the registry when the
    /// last window detaches from the session.
    func teardown() {
        creationOptionsStore.reset()
        hooksStore.reset()
        prMonitorsStore.reset()
        pullRequestListStore.reset()
        scriptMonitorsStore.reset()
        conversations.reset()
        agentDetails.reset()
        connection.disconnect()
    }
}

private struct WeakCoordinator {
    weak var value: AppCoordinator?
}
