import Foundation

func workspaceActivityDisplayTime(_ workspace: Workspace) -> TimeInterval {
    for raw in [workspace.lastActivity, workspace.createdAt, workspace.updatedAt] {
        if let date = ISO8601DateFormatter.lenientDate(from: raw) {
            let time = date.timeIntervalSince1970
            if time > 0 { return time }
        }
    }
    return 0
}

func isWorkspaceActivityMoreRecent(_ lhs: Workspace, than rhs: Workspace) -> Bool {
    workspaceActivityDisplayTime(lhs) > workspaceActivityDisplayTime(rhs)
}
