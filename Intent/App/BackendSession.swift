import Foundation
import Observation

/// The connection surface a `BackendSession` owns: the routing seam the
/// stores already depend on, plus explicit teardown for session release.
/// `ConnectionManager` conforms as-is; tests inject fakes.
@MainActor
protocol SessionConnectionManaging: ConnectionManagerRouting {
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

    let kind: Kind
    let connection: any SessionConnectionManaging
    let workspaceStore: WorkspaceStore
    let coordinator: AppCoordinator
    let prMonitorsStore: WorkspacePrMonitorsStore
    let attachmentUploadService: AttachmentUploadService
    let workspaceFileImageLoader: WorkspaceFileImageLoader
    let attachmentImageLoader: AttachmentImageLoader
    let attentionCueCenter: WorkspaceAttentionCueCenter

    /// The backend this session is pinned to; nil for the default session.
    var pinnedBackendID: BackendID? {
        if case .pinned(let id) = kind { return id }
        return nil
    }

    init(
        kind: Kind,
        connection: any SessionConnectionManaging,
        workspaceStore: WorkspaceStore,
        coordinator: AppCoordinator,
        prMonitorsStore: WorkspacePrMonitorsStore,
        attachmentUploadService: AttachmentUploadService,
        workspaceFileImageLoader: WorkspaceFileImageLoader,
        attachmentImageLoader: AttachmentImageLoader,
        attentionCueCenter: WorkspaceAttentionCueCenter
    ) {
        self.kind = kind
        self.connection = connection
        self.workspaceStore = workspaceStore
        self.coordinator = coordinator
        self.prMonitorsStore = prMonitorsStore
        self.attachmentUploadService = attachmentUploadService
        self.workspaceFileImageLoader = workspaceFileImageLoader
        self.attachmentImageLoader = attachmentImageLoader
        self.attentionCueCenter = attentionCueCenter
    }

    /// Disconnects the backend connection. Called by the registry when the
    /// last window detaches from a pinned session; never called on the
    /// default session.
    func teardown() {
        connection.disconnect()
    }
}
