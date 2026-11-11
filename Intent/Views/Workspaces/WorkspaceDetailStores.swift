import Foundation
import Observation

/// The per-workspace-page stores over the page's session connection. A window
/// keeps the stores of its most recently viewed workspaces in
/// `WorkspaceDetailStoresCache`, so they stay readable during a connection drop.
@MainActor
@Observable
final class WorkspaceDetailStores {
    let agentStore: AgentStore
    let viewModel: AgentListViewModel
    let noteStore: NoteStore
    let scriptStore: WorkspaceScriptStore
    let changesStore: WorkspaceChangesStore
    let filesStore: WorkspaceFilesStore
    @ObservationIgnored private var consumers: Set<UUID> = []

    convenience init(session: BackendSession) {
        self.init(connection: session.connection, summaries: session.agentSummaries)
    }

    init(connection: any ConnectionManagerRouting, summaries: AgentSummaryStore) {
        let agentStore = AgentStore(connectionManager: connection, summaries: summaries, scopedLoading: true)
        self.agentStore = agentStore
        viewModel = AgentListViewModel(list: agentStore.list)
        noteStore = NoteStore(connectionManager: connection)
        scriptStore = WorkspaceScriptStore(connection: connection)
        changesStore = WorkspaceChangesStore(connectionManager: connection)
        filesStore = WorkspaceFilesStore(connection: connection)
    }

    func retain(_ consumer: UUID, workspaceId: String) {
        let wasEmpty = consumers.isEmpty
        consumers.insert(consumer)
        if wasEmpty {
            agentStore.resumeObservation()
            noteStore.resumeObservation(workspaceId: workspaceId)
            scriptStore.resumeObservation()
        }
    }

    func release(_ consumer: UUID) {
        guard consumers.remove(consumer) != nil, consumers.isEmpty else { return }
        agentStore.suspendObservation()
        noteStore.suspendObservation()
        scriptStore.suspendObservation()
    }
}

/// Per window: the stores of the last few workspaces viewed. Not observable —
/// a lookup during view evaluation must not invalidate the view.
@MainActor
final class WorkspaceDetailStoresCache {
    static let retainedWorkspaceLimit = 5
    private var recent = RecentRetention<String, WorkspaceDetailStores>(capacity: retainedWorkspaceLimit)

    func stores(for workspaceId: String, make: () -> WorkspaceDetailStores) -> WorkspaceDetailStores {
        let stores = recent.value(for: workspaceId) ?? make()
        if recent.keys.last != workspaceId { recent.touch(workspaceId, value: stores) }
        return stores
    }

    func removeAll() {
        recent.removeAll()
    }
}
