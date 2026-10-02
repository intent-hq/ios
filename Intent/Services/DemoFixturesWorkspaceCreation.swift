import Foundation

extension DemoFixtures {
    private static var newRepositoryAttempt: NewRepositoryAttempt?
    /// GitHub creation stays unsupported; new-repository creation simulates a failed attempt and same-key retry.
    static func workspaceCreationResponse(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "github.authStatus":
            return ["isConfigured": !ProcessInfo.processInfo.arguments.contains("--demo-github-disconnected")]
        case "host.directoryStatus":
            let path = params["path"] as? String ?? ""
            return ["exists": path.hasSuffix("/existing-project") || newRepositoryAttempt?.path == path, "path": path]
        case "workspace.create" where params["isNewRepo"] as? Bool == true:
            return newRepositoryCreationResponse(params: params)
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
                    [
                        "id": "named-model", "name": "Named Model", "provider": provider, "isDefault": false,
                        "effortLevels": ["low", "medium", "high"]
                    ]
                ]
            ]
        default:
            return [String: Any]()
        }
    }

    private static func newRepositoryCreationResponse(params: [String: Any]) -> Any {
        guard let path = params["repositoryPath"] as? String,
              let key = params["idempotencyKey"] as? String else { return [String: Any]() }
        if let attempt = newRepositoryAttempt, attempt.retryKey(for: path) == key {
            return ["workspace": ["id": "demo-new-repository", "title": "My New Project", "repositoryPath": path]]
        }
        newRepositoryAttempt = NewRepositoryAttempt(path: path, idempotencyKey: key)
        return [String: Any]()
    }
}
