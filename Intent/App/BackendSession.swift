import Combine
import Foundation
import Observation

@MainActor
protocol SessionConnectionManaging: ConnectionManagerRouting {
    var connectionState: ConnectionState { get set }
    var certMismatches: [HostCertMismatch] { get }
    var startupState: DaemonStartupState? { get }
    var certMismatchDetected: Bool { get set }
    var certMismatchPublisher: AnyPublisher<Bool, Never> { get }
    var tunnelDialer: any TunnelDialing { get }
    var globalSubscriptionState: ConnectionManager.GlobalSubscriptionState { get }
    var reconnectStopReason: String? { get }

    var currentPrincipal: ConnectionPrincipal? { get }
    var lastConnectedPrincipal: ConnectionPrincipal? { get }
    var admission: ConnectionAdmission? { get }
    var pairingAttemptID: UUID? { get }
    var connectAttemptCount: Int { get }

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
    func connectDemo(serveFixtures: Bool)
    #endif
    func disconnect()
}

extension SessionConnectionManaging {
    var connectAttemptCount: Int { 0 }
    var startupState: DaemonStartupState? { nil }
    var lastConnectedPrincipal: ConnectionPrincipal? { nil }
    var reconnectStopReason: String? { nil }

    func makeBrowserProxy() throws -> any BrowserProxySession {
        throw BrowserTunnelError.unavailable
    }
}

extension ConnectionManager: SessionConnectionManaging {}

@MainActor
@Observable
final class BackendSession {
    typealias CoordinatorFactory =
        @MainActor (_ claimScreenRestoration: @escaping @MainActor () -> Bool) -> AppCoordinator

    let backendID: BackendID?
    let connection: any SessionConnectionManaging
    let workspaceStore: WorkspaceStore
    let assistantStore: AssistantStore
    let agentDetails: AgentDetailStore
    var agentSummaries: AgentSummaryStore { agentDetails.summaries }
    let conversations: ConversationStorePool
    let githubRepoStore: GitHubRepoStore
    let creationOptionsStore: CreationOptionsStore
    let hooksStore: WorkspaceStatusStore<BackgroundHook>
    let scriptMonitorsStore: WorkspaceScriptMonitorsStore
    let prMonitorsStore: WorkspacePrMonitorsStore
    let pullRequestListStore: PullRequestListStore
    let mobileTerminalStore: MobileTerminalStore
    let browserStore: WorkspaceBrowserStore
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
        self.attachmentUploadService = attachmentUploadService
        self.workspaceFileImageLoader = workspaceFileImageLoader
        self.attachmentImageLoader = attachmentImageLoader
        self.attentionCueCenter = attentionCueCenter
    }

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

    func repairConnection(leaving: AppCoordinator?) {
        coordinators.removeAll { $0.value == nil }
        coordinators
            .compactMap(\.value)
            .first { $0 !== leaving && !$0.lifecycleState.hasReturnedToSavedMachines }?
            .redialWindowBackend()
    }

    func claimScreenRestoration() -> Bool {
        guard backendID != nil, !screenRestorationClaimed else { return false }
        screenRestorationClaimed = true
        return true
    }

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
