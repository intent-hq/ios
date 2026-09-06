import Foundation
import Observation

/// Process-global map of `BackendID` → `BackendSession`.
///
/// Pinned sessions are created on first attach, shared by later attaches
/// (one attach per window showing the backend), and torn down — disconnect
/// + release — when the last window detaches. The default session is
/// created on first access and persists for the app's lifetime.
///
/// Observable so pinned windows can react to `removedBackendIDs`: backends
/// whose saved connection was deleted this run (spec decision 2) auto-close
/// their windows.
@MainActor
@Observable
final class BackendSessionRegistry {
    static let shared = BackendSessionRegistry()

    /// Builds a session for a kind. Defaults to the live composition root;
    /// tests inject a factory producing sessions over fakes.
    typealias SessionFactory = @MainActor (BackendSession.Kind) -> BackendSession

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private var pinned: [BackendID: BackendSession] = [:]
    @ObservationIgnored private var attachCounts: [BackendID: Int] = [:]
    @ObservationIgnored private var defaultSessionStorage: BackendSession?

    /// Backends whose saved connection was removed while the app runs (user
    /// delete, log off, or a synced tombstone). Pinned windows observe this
    /// to auto-close (spec decision 2); marking never tears a session down
    /// by itself — the closing window's detach drives the normal teardown.
    private(set) var removedBackendIDs: Set<BackendID> = []

    /// Called after a session is created (default or pinned) so process-wide
    /// aggregators (e.g. `NotificationManager`) can observe its connection.
    @ObservationIgnored var onSessionCreated: ((BackendSession) -> Void)?

    /// Called when a pinned session is released on last detach, before its
    /// connection is torn down. Never called for the default session.
    @ObservationIgnored var onSessionTeardown: ((BackendSession) -> Void)?

    init(makeSession: @escaping SessionFactory = BackendSessionRegistry.makeLiveSession) {
        self.makeSession = makeSession
    }

    // MARK: - Default session

    /// The session tracking the active connection (today's iOS semantics).
    /// Created on first access; never torn down.
    var defaultSession: BackendSession {
        if let session = defaultSessionStorage { return session }
        let session = makeSession(.defaultSession)
        defaultSessionStorage = session
        onSessionCreated?(session)
        return session
    }

    // MARK: - Pinned sessions

    /// The session for `id`, created on first attach and shared afterwards.
    /// Every attach must be balanced by a `detach(_:)`.
    func attach(_ id: BackendID) -> BackendSession {
        let session: BackendSession
        if let existing = pinned[id] {
            session = existing
        } else {
            session = makeSession(.pinned(id))
            pinned[id] = session
            onSessionCreated?(session)
        }
        attachCounts[id, default: 0] += 1
        return session
    }

    /// Balances one `attach(_:)`. The last detach disconnects the session's
    /// backend connection and releases it; a later attach for the same
    /// backend creates a fresh session. Unbalanced detaches are no-ops.
    func detach(_ id: BackendID) {
        guard let count = attachCounts[id] else { return }
        guard count <= 1 else {
            attachCounts[id] = count - 1
            return
        }
        attachCounts[id] = nil
        let session = pinned.removeValue(forKey: id)
        if let session {
            onSessionTeardown?(session)
            session.teardown()
        }
    }

    /// The live pinned session for `id` without attaching, if any.
    func pinnedSession(for id: BackendID) -> BackendSession? {
        pinned[id]
    }

    /// Number of windows currently attached to `id`.
    func attachmentCount(for id: BackendID) -> Int {
        attachCounts[id] ?? 0
    }

    /// Backends that currently have a live pinned session.
    var pinnedBackendIDs: [BackendID] {
        Array(pinned.keys)
    }

    // MARK: - Removed backends (spec decision 2)

    /// Whether `id`'s saved connection was removed this run.
    func isBackendRemoved(_ id: BackendID) -> Bool {
        removedBackendIDs.contains(id)
    }

    /// Marks a backend's saved connection as removed so any pinned window on
    /// it auto-closes. Idempotent.
    func markBackendRemoved(_ id: BackendID) {
        removedBackendIDs.insert(id)
    }

    /// Marks several backends removed at once (synced-merge tombstones).
    func markBackendsRemoved(_ ids: [BackendID]) {
        guard !ids.isEmpty else { return }
        removedBackendIDs.formUnion(ids)
    }

    /// Clears removal marks for backends whose saved connection reappeared
    /// (a synced merge re-added the same record id), so a later pinned
    /// window on the resurrected backend is not closed on sight.
    func clearRemovedMarks(_ ids: [BackendID]) {
        guard !ids.isEmpty else { return }
        removedBackendIDs.subtract(ids)
    }

    // MARK: - Live composition

    /// Composition root for real sessions: the default session wraps the
    /// existing process-wide `.shared` instances (unchanged iOS semantics);
    /// pinned sessions get fresh per-backend instances.
    static func makeLiveSession(kind: BackendSession.Kind) -> BackendSession {
        switch kind {
        case .defaultSession:
            let connection = ConnectionManager.shared
            let workspaceStore = WorkspaceStore.shared
            return BackendSession(
                kind: kind,
                connection: connection,
                workspaceStore: workspaceStore,
                coordinatorFactory: { claim in
                    AppCoordinator(
                        workspaceStore: workspaceStore, connection: connection,
                        claimScreenRestoration: claim)
                },
                prMonitorsStore: .shared,
                attachmentUploadService: .shared,
                workspaceFileImageLoader: .shared,
                attachmentImageLoader: .shared,
                attentionCueCenter: .shared)
        case .pinned(let id):
            let connection = ConnectionManager()
            let workspaceStore = WorkspaceStore(connectionManager: connection)
            let fileLoader = WorkspaceFileImageLoader(connection: connection)
            return BackendSession(
                kind: kind,
                connection: connection,
                workspaceStore: workspaceStore,
                coordinatorFactory: { claim in
                    AppCoordinator(
                        workspaceStore: workspaceStore, connection: connection,
                        pinnedBackendID: id,
                        claimScreenRestoration: claim)
                },
                prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
                attachmentUploadService: AttachmentUploadService(connection: connection),
                workspaceFileImageLoader: fileLoader,
                attachmentImageLoader: AttachmentImageLoader(
                    connection: connection, fileLoader: fileLoader),
                attentionCueCenter: WorkspaceAttentionCueCenter())
        }
    }
}
