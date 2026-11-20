import Foundation
import Observation

@MainActor
@Observable
final class BackendSessionRegistry {
    static let shared = BackendSessionRegistry()

    typealias SessionFactory = @MainActor (BackendID?) -> BackendSession

    @ObservationIgnored private let makeSession: SessionFactory
    @ObservationIgnored private var sessions: [BackendID: BackendSession] = [:]
    @ObservationIgnored private var attachCounts: [BackendID: Int] = [:]
    @ObservationIgnored private var pendingConnectionSelections: Set<BackendID> = []

    private(set) var removedBackendIDs: Set<BackendID> = []

    @ObservationIgnored var onSessionCreated: ((BackendSession) -> Void)?

    @ObservationIgnored var onSessionTeardown: ((BackendSession) -> Void)?

    @ObservationIgnored var onBackendsRemoved: (([BackendID]) -> Void)?

    init(makeSession: @escaping SessionFactory = BackendSessionRegistry.makeLiveSession) {
        self.makeSession = makeSession
    }

    // MARK: - Backend sessions

    func markConnectionSelected(_ id: BackendID) {
        pendingConnectionSelections.insert(id)
    }

    func consumeConnectionSelection(for id: BackendID?) -> Bool {
        guard let id else { return false }
        return pendingConnectionSelections.remove(id) != nil
    }

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

    func session(for id: BackendID) -> BackendSession? {
        sessions[id]
    }

    func attachmentCount(for id: BackendID) -> Int {
        attachCounts[id] ?? 0
    }

    var liveBackendIDs: [BackendID] {
        Array(sessions.keys)
    }

    // MARK: - Pairing sessions

    func makePairingSession() -> BackendSession {
        makeSession(nil)
    }

    // MARK: - Removed backends (spec decision 2)

    func isBackendRemoved(_ id: BackendID) -> Bool {
        removedBackendIDs.contains(id)
    }

    func markBackendRemoved(_ id: BackendID) {
        removedBackendIDs.insert(id)
        onBackendsRemoved?([id])
    }

    func markBackendsRemoved(_ ids: [BackendID]) {
        guard !ids.isEmpty else { return }
        removedBackendIDs.formUnion(ids)
        onBackendsRemoved?(ids)
    }

    func clearRemovedMarks(_ ids: [BackendID]) {
        guard !ids.isEmpty else { return }
        removedBackendIDs.subtract(ids)
    }

    // MARK: - Live composition

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
                    workspaceStore: workspaceStore,
                    connection: connection,
                    backendID: backendID,
                    syncedRegistry: DemoMode.isEnabled ? SyncedBackendRegistry(accessGroup: nil) : SyncedBackendRegistry(),
                    claimScreenRestoration: claim,
                    agentHistory: .shared
                )
            },
            githubRepoStore: GitHubRepoStore(connectionManager: connection),
            creationOptionsStore: CreationOptionsStore(connectionManager: connection),
            prMonitorsStore: WorkspacePrMonitorsStore(connectionManager: connection),
            attachmentUploadService: AttachmentUploadService(connection: connection),
            workspaceFileImageLoader: fileLoader,
            attachmentImageLoader: AttachmentImageLoader(
                connection: connection,
                fileLoader: fileLoader
            ),
            attentionCueCenter: WorkspaceAttentionCueCenter()
        )
    }
}
