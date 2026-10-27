import Foundation

enum WorkspaceSidebarContent: Equatable {
    case workspace(id: String)
    case workspaceList
}

/// A persistent sidebar shows the open workspace beside its agent or note.
/// Back returns it to the list for the current route only; the next agent
/// or note selection shows the workspace again.
struct WorkspaceSidebarState: Equatable {
    private var listRoute: Route?

    struct Route: Equatable {
        let screen: String
        let requestId: Int
    }

    func content(for screen: AppScreen, route: Route, isPersistent: Bool) -> WorkspaceSidebarContent {
        guard isPersistent, listRoute != route else { return .workspaceList }
        switch screen {
        case let .agentConversation(_, workspaceId, _), let .noteDetail(_, workspaceId, _):
            return workspaceId == Workspace.chiefWorkspaceId ? .workspaceList : .workspace(id: workspaceId)
        default:
            return .workspaceList
        }
    }

    mutating func showList(for route: Route) {
        listRoute = route
    }
}

extension AppCoordinator {
    var workspaceSidebarRoute: WorkspaceSidebarState.Route {
        WorkspaceSidebarState.Route(screen: currentScreenDescription, requestId: conversationRequestId)
    }
}
