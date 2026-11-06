import Observation

/// The per-workspace-page stores, created once per page over the page's session connection.
/// The page owns one instance for its lifetime; switching workspaces resets the stores in place.
@MainActor
@Observable
final class WorkspaceDetailStores {
    let agentStore: AgentStore
    let viewModel: AgentListViewModel
    let noteStore: NoteStore
    let scriptStore: WorkspaceScriptStore
    let changesStore: WorkspaceChangesStore
    let filesStore: WorkspaceFilesStore

    init(session: BackendSession) {
        let agentStore = AgentStore(connectionManager: session.connection, summaries: session.agentSummaries, scopedLoading: true)
        self.agentStore = agentStore
        viewModel = AgentListViewModel(list: agentStore.list)
        noteStore = NoteStore(connectionManager: session.connection)
        scriptStore = WorkspaceScriptStore(connection: session.connection)
        changesStore = WorkspaceChangesStore(connectionManager: session.connection)
        filesStore = WorkspaceFilesStore(connection: session.connection)
    }
}
