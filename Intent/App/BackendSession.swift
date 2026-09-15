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
    /// Raised when a pinned certificate changed; the coordinator clears it
    /// once it has routed to the failure screen.
    var certMismatchDetected: Bool { get set }
    var certMismatchPublisher: AnyPublisher<Bool, Never> { get }
    /// Dialer used to probe a server certificate over a Tailcat tunnel.
    var tunnelDialer: any TunnelDialing { get }

    func connect(
        hosts: [String], port: Int, token: String, certFingerprint: String?,
        tcAddress: String?
    ) async throws
    func updateCachedCredentials(
        hosts: [String], port: Int, token: String, certFingerprint: String?,
        tcAddress: String?
    )
    func refreshHostRoutes() async
    func disconnect()
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
    /// Session-lifetime GitHub repo cache for the New Workspace repo step;
    /// outlives the sheet so a reopen renders the cached list instantly.
    let githubRepoStore: GitHubRepoStore
    let prMonitorsStore: WorkspacePrMonitorsStore
    let attachmentUploadService: AttachmentUploadService
    let workspaceFileImageLoader: WorkspaceFileImageLoader
    let attachmentImageLoader: AttachmentImageLoader
    let attentionCueCenter: WorkspaceAttentionCueCenter

    private let coordinatorFactory: CoordinatorFactory
    private var screenRestorationClaimed = false

    init(
        backendID: BackendID?,
        connection: any SessionConnectionManaging,
        workspaceStore: WorkspaceStore,
        coordinatorFactory: @escaping CoordinatorFactory,
        githubRepoStore: GitHubRepoStore,
        prMonitorsStore: WorkspacePrMonitorsStore,
        attachmentUploadService: AttachmentUploadService,
        workspaceFileImageLoader: WorkspaceFileImageLoader,
        attachmentImageLoader: AttachmentImageLoader,
        attentionCueCenter: WorkspaceAttentionCueCenter
    ) {
        self.backendID = backendID
        self.connection = connection
        self.workspaceStore = workspaceStore
        self.coordinatorFactory = coordinatorFactory
        self.githubRepoStore = githubRepoStore
        self.prMonitorsStore = prMonitorsStore
        self.attachmentUploadService = attachmentUploadService
        self.workspaceFileImageLoader = workspaceFileImageLoader
        self.attachmentImageLoader = attachmentImageLoader
        self.attentionCueCenter = attentionCueCenter
    }

    /// A fresh coordinator for one window over this session. Windows sharing
    /// the session share connection + stores but navigate independently
    /// (spec "State split"); the coordinator claims last-screen restoration
    /// lazily via `claimScreenRestoration()`.
    func makeCoordinator() -> AppCoordinator {
        coordinatorFactory { [weak self] in
            self?.claimScreenRestoration() ?? false
        }
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

    /// Disconnects the backend connection. Called by the registry when the
    /// last window detaches from the session.
    func teardown() {
        connection.disconnect()
    }
}
