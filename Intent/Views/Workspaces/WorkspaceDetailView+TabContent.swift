import SwiftUI

/// The selected tab's content: the agents and workspace resources, the changes, or the context.
extension WorkspaceDetailView {
    private var showsAgentLoading: Bool {
        (agentStore.isLoading || !agentStore.hasLoaded) && viewModel.agents.isEmpty && !hasWorkspaceResources
    }
    var showsAgentList: Bool { !showsAgentLoading && (viewModel.hasAgentSections || hasWorkspaceResources) }
    var hasWorkspaceResources: Bool {
        !terminalStore.activeTerminals(workspaceId: workspaceId).isEmpty
            || !browserStore.browsers(workspaceId: workspaceId).isEmpty
            || browserStore.errorMessage(workspaceId: workspaceId) != nil
            || !scriptStore.scriptsWithRuns(workspaceId: workspaceId).isEmpty
            || scriptStore.errorMessage(workspaceId: workspaceId) != nil
    }

    @ViewBuilder
    var tabContent: some View {
        if currentTab == .agents {
            if showsAgentLoading {
                ProgressView { Text("Loading agents...").interFont(Constants.Typography.bodyS) }
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
            } else if !viewModel.hasAgentSections, !hasWorkspaceResources {
                ContentUnavailableView {
                    Label { Text("No Agents").interFont(Constants.Typography.bodyM.withFace(.semibold)) } icon: {
                        Image(.agents).resizable().scaledToFit().frame(width: emptyStateIconSize, height: emptyStateIconSize)
                    }
                } description: { Text("Agents will appear here when active.").interFont(Constants.Typography.bodyS) }
                .frame(maxWidth: .infinity, minHeight: Constants.WorkspaceList.emptyStateHeight)
            } else {
                agentListContent
            }
        } else if currentTab == .changes {
            WorkspaceChangesView(workspaceId: workspaceId, store: changesStore)
        } else {
            WorkspaceContextView(workspaceId: workspaceId, noteStore: noteStore, filesStore: filesStore, notesExpanded: notesExpansion, filesExpanded: filesExpansion)
        }
    }

    @ViewBuilder
    private var agentListContent: some View {
        let rows = agentListRows
        let entries = rows.enumerated().map { index, row in
            (id: row.id, content: WorkspaceAgentListEntry(row: row, isFirst: index == 0))
        }
        ForEach(snapshots: entries, id: \.id) { entry in entry.content }
        if hasWorkspaceResources {
            WorkspaceDetailResources(
                workspaceId: workspaceId,
                terminalStore: terminalStore,
                browserStore: browserStore,
                scriptStore: scriptStore,
                revealedTarget: swipeTarget,
                followsAgents: !rows.isEmpty,
                onSelectTerminal: { presentation.selectedTerminal = $0 },
                onSelectBrowser: { presentation.selectedBrowser = $0 }
            )
        }
    }
}
