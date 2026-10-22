import Foundation

@MainActor
final class DemoHostSettingsFixtures {
    private var content = "Use plain English. Keep changes focused and explain how you verified them."
    private var enabled = true
    private var enabledProviders = ["auggie": true, "codex": true]

    func response(for method: String, params: [String: Any]) throws -> Any? {
        guard ProcessInfo.processInfo.arguments.contains("--demo-settings") else { return nil }
        if let response = try rulesResponse(for: method, params: params) { return response }
        switch method {
        case "providers.catalog":
            return [
                "providers": [
                    [
                        "id": "codex", "displayName": "OpenAI Codex", "visible": true,
                        "canBeDisabled": true, "supportsTestPrompt": true
                    ],
                    [
                        "id": "auggie", "displayName": "Augment Auggie", "visible": true,
                        "canBeDisabled": true, "supportsTestPrompt": true
                    ]
                ]
            ]
        case "host.providerTestPrompt":
            return ["ok": true]
        case "settings.get" where params["path"] as? String == "providers.enabled":
            return ["path": "providers.enabled", "value": enabledProviders]
        case "settings.update":
            let changes = params["changes"] as? [[String: Any]] ?? []
            for change in changes where change["path"] as? String == "providers.enabled" {
                if let value = change["value"] as? [String: Bool] { enabledProviders = value }
            }
            return ["applied": changes, "revision": 1]
        default:
            return nil
        }
    }

    private func rulesResponse(for method: String, params: [String: Any]) throws -> Any? {
        switch method {
        case "rules.get" where params["ruleType"] as? String == "base-system-prompt":
            return ["enabled": enabled, "content": content, "updatedAt": 0]
        case "rules.update" where params["ruleType"] as? String == "base-system-prompt":
            if ProcessInfo.processInfo.arguments.contains("--demo-settings-save-failure") {
                throw NSError(domain: "DemoSettings", code: -1)
            }
            content = params["content"] as? String ?? content
            enabled = params["enabled"] as? Bool ?? enabled
            let entry: [String: Any] = [
                "ruleType": "base-system-prompt", "source": "user-override", "content": content,
                "enabled": enabled, "editable": true, "updatedAt": 0
            ]
            return ["rules": ["workspaceId": "global", "rules": [entry]]]
        default:
            return nil
        }
    }
}
