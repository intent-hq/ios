#if DEBUG
import Foundation

extension DemoFixtures {
    private static var workspaceCreationKeys: [WorkspaceRepositorySource: String] = [:]

    static func workspaceCreationResponse(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "github.authStatus":
            return ["isConfigured": !ProcessInfo.processInfo.arguments.contains("--demo-github-disconnected")]
        case "host.directoryStatus":
            let path = params["path"] as? String ?? ""
            return ["exists": path.hasSuffix("/existing-project") || workspaceCreationKeys[.newRepository(path: path)] != nil, "path": path]
        case "workspace.create":
            return workspaceCreateResponse(params: params)
        case "github.repos.list":
            return [
                "repos": [
                    ["owner": "nova-labs", "name": "console", "defaultBranch": "main"],
                    ["owner": "nova-labs", "name": "docs", "defaultBranch": "main"]
                ]
            ]
        case "github.branches.list", "github.branches.listCached":
            return ["branches": ["main", "feature/docs"], "defaultBranch": "main"]
        default:
            return providerOptionsResponse(for: method, params: params)
        }
    }

    private static func providerOptionsResponse(for method: String, params: [String: Any]) -> Any {
        switch method {
        case "providers.catalog":
            let providers = ["auggie", "codex"].map { id in
                ["id": id, "visible": true, "canBeDisabled": true] as [String: Any]
            }
            return ["providers": providers]
        case "settings.get" where params["path"] as? String == "providers.enabled":
            return ["path": "providers.enabled", "value": ["auggie": true, "codex": true]]
        case "settings.get" where params["path"] as? String == "model.defaultProvider":
            return ["path": "model.defaultProvider", "value": "codex"]
        case "host.providerAuthStatus":
            let providers = ["auggie", "codex"].map { id in
                ["id": id, "authenticated": true] as [String: Any]
            }
            return ["providers": providers]
        case "models.list":
            let provider = params["providerId"] as? String ?? "auggie"
            if ProcessInfo.processInfo.arguments.contains("--demo-model-catalog-empty") {
                return ["models": [[String: Any]]()]
            }
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

    private static func workspaceCreateResponse(params: [String: Any]) -> Any {
        if params["isNewRepo"] as? Bool == true {
            guard let path = params["repositoryPath"] as? String else { return [String: Any]() }
            return workspaceCreationRetryResponse(source: .newRepository(path: path), path: path, params: params)
        }
        guard ProcessInfo.processInfo.arguments.contains("--demo-github-create-retry"),
              let url = params["githubUrl"] as? String, let branch = params["baseRef"] as? String else { return [String: Any]() }
        return workspaceCreationRetryResponse(source: .github(url: url, baseRef: branch), path: "~/Developer/console", params: params)
    }

    private static func workspaceCreationRetryResponse(source: WorkspaceRepositorySource, path: String, params: [String: Any]) -> Any {
        guard let key = params["idempotencyKey"] as? String else { return [String: Any]() }
        if workspaceCreationKeys[source] == key {
            return ["workspace": ["id": "demo-retried-workspace", "title": "My New Project", "repositoryPath": path]]
        }
        workspaceCreationKeys[source] = key
        return [String: Any]()
    }
}

extension DemoFixtures {
    // MARK: - Specialists

    static var specialists: [[String: Any]] {
        [
            [
                "id": "implementor",
                "name": "Implementor",
                "description": "Implements a scoped task end to end."
            ],
            [
                "id": "verifier",
                "name": "Verifier",
                "description": "Reviews and verifies completed work."
            ]
        ]
    }
}
#endif
