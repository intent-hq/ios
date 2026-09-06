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
/// the registry's live factory composes the object graph (the default
/// session over the existing `.shared` instances, pinned sessions over
/// fresh per-backend instances).
@MainActor
@Observable
final class BackendSession {
    /// How the session is bound to a backend.
    enum Kind: Equatable {
        /// Tracks the active connection and supports in-place switching
        /// (today's iOS semantics; used by the default window on both
        /// platforms). Persists for the app's lifetime.
        case defaultSession
        /// Bound to one saved backend; exists only while at least one
        /// visionOS window shows it.
        case pinned(BackendID)
    }

    /// Builds a per-window coordinator bound to this session's connection and
    /// stores. `claimScreenRestoration` is the coordinator's lazy hook into
    /// `claimScreenRestoration()` below.
    typealias CoordinatorFactory =
        @MainActor (_ claimScreenRestoration: @escaping @MainActor () -> Bool) -> AppCoordinator

    let kind: Kind
    let connection: any SessionConnectionManaging
    let workspaceStore: WorkspaceStore
    let prMonitorsStore: WorkspacePrMonitorsStore
    let attachmentUploadService: AttachmentUploadService
    let workspaceFileImageLoader: WorkspaceFileImageLoader
    let attachmentImageLoader: AttachmentImageLoader
    let attentionCueCenter: WorkspaceAttentionCueCenter

    private let coordinatorFactory: CoordinatorFactory
    private var screenRestorationClaimed = false

    /// The backend this session is pinned to; nil for the default session.
    var pinnedBackendID: BackendID? {
        if case .pinned(let id) = kind { return id }
        return nil
    }

    init(
        kind: Kind,
        connection: any SessionConnectionManaging,
        workspaceStore: WorkspaceStore,
        coordinatorFactory: @escaping CoordinatorFactory,
        prMonitorsStore: WorkspacePrMonitorsStore,
        attachmentUploadService: AttachmentUploadService,
        workspaceFileImageLoader: WorkspaceFileImageLoader,
        attachmentImageLoader: AttachmentImageLoader,
        attentionCueCenter: WorkspaceAttentionCueCenter
    ) {
        self.kind = kind
        self.connection = connection
        self.workspaceStore = workspaceStore
        self.coordinatorFactory = coordinatorFactory
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

    /// Grants last-screen restoration to the first default-session claimant
    /// only (spec decision 1b): duplicated default windows and pinned windows
    /// start at the workspace list and never write last-screen state.
    func claimScreenRestoration() -> Bool {
        guard kind == .defaultSession, !screenRestorationClaimed else { return false }
        screenRestorationClaimed = true
        return true
    }

    /// Disconnects the backend connection. Called by the registry when the
    /// last window detaches from a pinned session; never called on the
    /// default session.
    func teardown() {
        connection.disconnect()
    }
}
