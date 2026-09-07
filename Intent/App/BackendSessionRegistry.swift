import Foundation
import Observation

/// Process-global map of `BackendID` → `BackendSession`.
///
/// Sessions are created on first attach, shared by later attaches (one
/// attach per window showing the backend), and torn down — disconnect
/// + release — when the last window detaches. There is no default session
/// (window model v2): every window is bound to exactly one backend.
///
/// Observable so windows can react to `removedBackendIDs`: backends whose
/// saved connection was deleted this run (spec decision 2) unbind or close
/// their windows.
@MainActor
@Observable
final class BackendSessionRegistry {
    static let shared = BackendSessionRegistry()

    /// Builds a session for a backend (nil = transient pairing session).
    /// Defaults to the live composition root; tests inject a factory
    /// producing sessions over fakes.
    typealias SessionFactory = @MainActor (BackendID?) -> BackendSession

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private var sessions: [BackendID: BackendSession] = [:]
    @ObservationIgnored private var attachCounts: [BackendID: Int] = [:]

    /// Backends whose saved connection was removed while the app runs (user
    /// delete, log off, or a synced tombstone). Windows observe this to
    /// unbind or auto-close (spec decision 2); marking never tears a session
    /// down by itself — the closing window's detach drives normal teardown.
    private(set) var removedBackendIDs: Set<BackendID> = []

    /// Called after a backend session is created so process-wide aggregators
    /// (e.g. `NotificationManager`) can observe its connection. Not called
    /// for transient pairing sessions.
    @ObservationIgnored var onSessionCreated: ((BackendSession) -> Void)?

    /// Called when a session is released on last detach, before its
    /// connection is torn down.
    @ObservationIgnored var onSessionTeardown: ((BackendSession) -> Void)?

    init(makeSession: @escaping SessionFactory = BackendSessionRegistry.makeLiveSession) {
        self.makeSession = makeSession
    }

    // MARK: - Backend sessions

    /// The session for `id`, created on first attach and shared afterwards.
    /// Every attach must be balanced by a `detach(_:)`.
    func attach(_ id: BackendID) -> BackendSession {
        let session: BackendSession
        if let existing = sessions[id] {
            session = existing
        } else {
            session = makeSession(id)
            sessions[id] = session
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
        let session = sessions.removeValue(forKey: id)
        if let session {
            onSessionTeardown?(session)
            session.teardown()
        }
    }

    /// The live session for `id` without attaching, if any.
    func session(for id: BackendID) -> BackendSession? {
        sessions[id]
    }

    /// Number of windows currently attached to `id`.
    func attachmentCount(for id: BackendID) -> Int {
        attachCounts[id] ?? 0
    }

    /// Backends that currently have a live session.
    var liveBackendIDs: [BackendID] {
        Array(sessions.keys)
    }

    // MARK: - Pairing sessions

    /// A fresh transient session (nil backendID) for a window that has no
    /// backend yet (first run, or unbound after removal). Not registered or
    /// refcounted: the owning window tears it down when pairing completes
    /// or the window closes.
    func makePairingSession() -> BackendSession {
        makeSession(nil)
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

    /// Composition root for real sessions: every session gets fresh
    /// per-backend instances (window model v2 — no `.shared` state split).
    static func makeLiveSession(backendID: BackendID?) -> BackendSession {
        let connection = ConnectionManager()
        let workspaceStore = WorkspaceStore(connectionManager: connection)
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        return BackendSession(
            backendID: backendID,
            connection: connection,
            workspaceStore: workspaceStore,
            coordinatorFactory: { claim in
                AppCoordinator(
                    workspaceStore: workspaceStore, connection: connection,
                    backendID: backendID,
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
