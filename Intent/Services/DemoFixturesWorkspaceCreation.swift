import Foundation

extension DemoFixtures {
    /// Read-only wizard fixtures for the Back/forward regression (#446).
    /// `workspace.create` deliberately remains unsupported: no workspace is made.
    static func workspaceCreationResponse(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "github.authStatus":
            return ["isConfigured": true]
        case "github.repos.list":
            return [
                "repos": [
                    ["owner": "nova-labs", "name": "console", "defaultBranch": "main"],
                    ["owner": "nova-labs", "name": "docs", "defaultBranch": "main"]
                ]
            ]
        case "github.branches.list", "github.branches.listCached":
            return ["branches": ["main", "feature/docs"], "defaultBranch": "main"]
        case "providers.catalog":
            let providers = ["auggie", "codex"].map { id in
                ["id": id, "visible": true, "canBeDisabled": true] as [String: Any]
            }
            return ["providers": providers]
        case "settings.get" where params["path"] as? String == "providers.enabled":
            return ["path": "providers.enabled", "value": ["auggie": true, "codex": true]]
        case "host.providerAuthStatus":
            let providers = ["auggie", "codex"].map { id in
                ["id": id, "authenticated": true] as [String: Any]
            }
            return ["providers": providers]
        case "models.list":
            let provider = params["providerId"] as? String ?? "auggie"
            return [
                "models": [
                    ["id": "default-model", "name": "Default Model", "provider": provider, "isDefault": true],
                    ["id": "named-model", "name": "Named Model", "provider": provider, "isDefault": false]
                ]
            ]
        default:
            return [String: Any]()
        }
    }
}
