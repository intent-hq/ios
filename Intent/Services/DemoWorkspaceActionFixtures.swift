import Foundation

@MainActor
enum DemoWorkspaceActionFixtures {
    private static var removedIDs: Set<String> = []

    static func response(for method: String, params: [String: Any]) -> Any? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--demo-workspace-actions") else { return nil }
        if method == "workspace.list" {
            return ["workspaces": DemoFixtures.workspaces.filter { !removedIDs.contains($0["id"] as? String ?? "") }]
        }
        guard ["workspace.archive", "workspace.delete"].contains(method),
              let workspaceId = params["workspaceId"] as? String,
              var workspace = DemoFixtures.workspaces.first(where: { $0["id"] as? String == workspaceId }) else { return nil }
        if arguments.contains("--demo-workspace-action-error") { return ["success": false] }
        removedIDs.insert(workspaceId)
        if method == "workspace.delete" { return ["success": true] }
        workspace["status"] = "Archived"
        workspace["archived"] = true
        return ["workspace": workspace]
    }
}
