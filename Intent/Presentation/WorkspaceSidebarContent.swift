import Foundation

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
    static func namesAgent(_ agentId: String, coordinator: AppCoordinator) -> Bool {
        guard coordinator.iPadNavigation.mainTool == nil else { return false }
        guard coordinator.usesIPadShell, case let .agentConversation(selectedId, workspaceId, _) = coordinator.currentScreen,
              selectedId == agentId,
              let listing = coordinator.workspaceSidebarAgents.listing,
              listing.workspaceId == workspaceId, listing.agentId == agentId else { return false }
        let navigation = coordinator.iPadNavigation
        return navigation.isSidebarVisible && !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
    }
}

struct WorkspaceSidebarAgents: Equatable {
    struct Handoff: Equatable {
        let workspaceId: String
        let expansion: AgentListViewModel.Expansion
    }

    struct Listing: Equatable {
        let workspaceId: String
        let agentId: String
        let owner: ObjectIdentifier
    }

    var handoff: Handoff?
    var listing: Listing?

    static func namesSelection(isListed: Bool, isInitialLoadPending: Bool, isRevealPending: Bool) -> Bool {
        isListed || isInitialLoadPending || isRevealPending
    }

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
