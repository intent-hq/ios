#if DEBUG
import Foundation

@MainActor
enum DemoWorkspaceActionFixtures {
    private static var removedIDs: Set<String> = []
    private static var archivedWorkspaces: [String: [String: Any]] = [:]
    private static var renamedTitles: [String: String] = [:]

    static func response(for method: String, params: [String: Any]) -> Any? {
        let arguments = LaunchOptions.current.arguments
        guard arguments.contains("--demo-workspace-actions") else { return nil }
        if method == "workspace.list" {
            let active = DemoFixtures.workspaces.filter { !removedIDs.contains($0["id"] as? String ?? "") }.map { original in
                var workspace = original
                if let id = workspace["id"] as? String, let title = renamedTitles[id] { workspace["title"] = title }
                return workspace
            }
            let archived = params["includeArchived"] as? Bool == true ? Array(archivedWorkspaces.values) : []
            return ["workspaces": active + archived]
        }
        guard ["workspace.archive", "workspace.delete", "workspace.update"].contains(method),
              let workspaceId = params["workspaceId"] as? String,
              var workspace = DemoFixtures.workspaces.first(where: { $0["id"] as? String == workspaceId }) else { return nil }
        if arguments.contains("--demo-workspace-action-error") { return ["success": false] }
        if method == "workspace.update", let title = params["title"] as? String {
            renamedTitles[workspaceId] = title
            workspace["title"] = title
            return ["workspace": workspace]
        }
        guard method != "workspace.update" else { return nil }
        removedIDs.insert(workspaceId)
        if method == "workspace.delete" {
            archivedWorkspaces.removeValue(forKey: workspaceId)
            return ["success": true]
        }
        workspace["status"] = "Archived"
        workspace["archived"] = true
        archivedWorkspaces[workspaceId] = workspace
        return ["workspace": workspace]
    }
}
#endif
