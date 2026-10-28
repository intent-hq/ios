import Foundation

/// A persistent sidebar shows the open workspace beside its agent or note;
/// the main view's Back returns both panes to the overview and the list.
enum WorkspaceSidebarContent: Equatable {
    case workspace(id: String)
    case workspaceList

    static func resolve(screen: AppScreen, isPersistent: Bool) -> Self {
        guard isPersistent else { return .workspaceList }
        switch screen {
        case let .agentConversation(_, workspaceId, _), let .noteDetail(_, workspaceId, _):
            return workspaceId == Workspace.chiefWorkspaceId ? .workspaceList : .workspace(id: workspaceId)
        default:
            return .workspaceList
        }
    }
}

extension WorkspaceSidebarContent {
    /// The persistent shell sidebar shows this agent selected inside its workspace. A child agent
    /// opened from the transcript is not the sidebar's selection, so it keeps its own title.
    static func namesAgent(_ agentId: String, coordinator: AppCoordinator) -> Bool {
        guard coordinator.usesIPadShell, case let .agentConversation(selectedId, workspaceId, _) = coordinator.currentScreen,
              selectedId == agentId,
              let listing = coordinator.workspaceSidebarAgents.listing,
              listing.workspaceId == workspaceId, listing.agentId == agentId else { return false }
        let navigation = coordinator.iPadNavigation
        return navigation.isSidebarVisible && !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
    }
}

/// Hands the overview's open sections to the sidebar copy of the workspace, and records which
/// open agent the sidebar actually lists: the conversation hides its title only for that agent.
struct WorkspaceSidebarAgents: Equatable {
    struct Handoff: Equatable {
        let workspaceId: String
        let expansion: AgentListViewModel.Expansion
    }

    struct Listing: Equatable {
        let workspaceId: String
        let agentId: String
        /// The sidebar list that reported it; a leaving copy clears only its own report.
        let owner: ObjectIdentifier
    }

    var handoff: Handoff?
    var listing: Listing?

    /// The sidebar names the open agent once its row is listed. While a read that could list it
    /// is in flight, it keeps the conversation from flashing a title; a failed or finished read
    /// without the row hands the name back to the conversation.
    static func namesSelection(isListed: Bool, isInitialLoadPending: Bool, isRevealPending: Bool) -> Bool {
        isListed || isInitialLoadPending || isRevealPending
    }

    /// Sections to open so the agent's row appears: each known ancestor's children,
    /// and the background section when the chain ends at a background agent.
    static func revealGroups(for agent: AgentSession, lookup: (String) -> AgentSession?) -> Set<AgentListGroup> {
        if agent.retiredAt != nil { return [.retired] }
        var groups: Set<AgentListGroup> = []
        var visited: Set<String> = []
        var current: AgentSession? = agent
        while let row = current, visited.insert(row.id).inserted {
            guard let parentId = AgentListViewModel.parent(of: row) else {
                if row.isBackground { groups.insert(.background) }
                break
            }
            groups.insert(.delegated(parentId: parentId))
            current = lookup(parentId)
        }
        return groups
    }
}
