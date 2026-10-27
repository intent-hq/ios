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
