import Foundation

@MainActor
enum DemoWorkspaceActionFixtures {
    private static var removedIDs: Set<String> = []
    private static var archivedWorkspaces: [String: [String: Any]] = [:]

    static func response(for method: String, params: [String: Any]) -> Any? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--demo-workspace-actions") else { return nil }
        if method == "workspace.list" {
            let active = DemoFixtures.workspaces.filter { !removedIDs.contains($0["id"] as? String ?? "") }
            let archived = params["includeArchived"] as? Bool == true ? Array(archivedWorkspaces.values) : []
            return ["workspaces": active + archived]
        }
        guard ["workspace.archive", "workspace.delete"].contains(method),
              let workspaceId = params["workspaceId"] as? String,
              var workspace = DemoFixtures.workspaces.first(where: { $0["id"] as? String == workspaceId }) else { return nil }
        if arguments.contains("--demo-workspace-action-error") { return ["success": false] }
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
