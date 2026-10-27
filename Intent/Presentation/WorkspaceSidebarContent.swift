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
        guard coordinator.usesIPadShell, case let .agentConversation(selectedId, _, _) = coordinator.currentScreen,
              selectedId == agentId else { return false }
        let navigation = coordinator.iPadNavigation
        return navigation.isSidebarVisible && !navigation.usesSidebarOverlay && !navigation.usesCompactNavigation
    }
}
