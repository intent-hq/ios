import Foundation

/// Mirrors cloudlands-fe's `workspace-activity-time.ts`: the activity time a
/// workspace sorts by is the first parseable of `lastActivity` → `createdAt`
/// → `updatedAt` (seconds since 1970), or 0 when none parses — so unstamped
/// workspaces sort last, exactly as in the desktop sidebar.
func workspaceActivityDisplayTime(_ workspace: Workspace) -> TimeInterval {
    for raw in [workspace.lastActivity, workspace.createdAt, workspace.updatedAt] {
        if let date = ISO8601DateFormatter.lenientDate(from: raw) {
            let time = date.timeIntervalSince1970
            if time > 0 { return time }
        }
    }
    return 0
}

/// `sorted(by:)` predicate ordering workspaces by activity time, most recent
/// first — the FE's `compareWorkspaceActivityDisplayTimeDesc`.
func isWorkspaceActivityMoreRecent(_ lhs: Workspace, than rhs: Workspace) -> Bool {
    workspaceActivityDisplayTime(lhs) > workspaceActivityDisplayTime(rhs)
}
