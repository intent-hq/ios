import Foundation

enum DemoBrowserFixtures {
    private static var scriptRuntimes: [String: [String: [String: Any]]] = [:]

    /// Nil keeps the ordinary demo transcript when this scenario was not requested.
    static var conversationMessages: [[String: Any]]? { // swiftlint:disable:this discouraged_optional_collection
        guard ProcessInfo.processInfo.arguments.contains("--demo-browsers") else { return nil }
        return [
            [
                "id": "demo-browser-assistant",
                "role": "assistant",
                "timestamp": DemoFixtures.transcriptIso(minutesAgo: 1),
                "contentBlocks": [
                    ["type": "text", "text": "[Open server preview](http://daemon.localhost:5173/preview?view=phone)"]
                ]
            ]
        ]
    }

    static func response(for method: String, params: [String: Any]) -> Any? {
        if ProcessInfo.processInfo.arguments.contains("--demo-scripts"),
           let response = scriptResponse(for: method, params: params) { return response }
        switch method {
        case "browser.listTabs":
            if ProcessInfo.processInfo.arguments.contains("--demo-browsers"),
               let workspaceId = params["workspaceId"] as? String {
                let tab: [String: Any] = [
                    "tabId": "demo-agent-browser", "workspaceId": workspaceId, "title": "Agent browser",
                    "hostClientId": "demo-desktop", "ownerAgentId": "demo-agent-implementor",
                    "url": "http://127.0.0.1:4173", "requestedUrl": "http://daemon.localhost:4173",
                    "visibility": "hidden", "hostConnected": true,
                    "createdAt": "2026-09-27T23:00:00Z", "updatedAt": "2026-09-27T23:00:00Z"
                ]
                return ["tabs": [tab]]
            }
            return ["tabs": [[String: Any]]()]
        case "script.list":
            if ProcessInfo.processInfo.arguments.contains("--demo-browsers"),
               let workspaceId = params["workspaceId"] as? String {
                let script: [String: Any] = [
                    "id": "preview", "workspaceId": workspaceId, "name": "Web preview",
                    "command": "npm run dev",
                    "runtime": ["status": "running", "detectedUrl": "http://localhost:5173", "restartCount": 0]
                ]
                return ["scripts": [script]]
            }
            return ["scripts": [[String: Any]]()]
        case "events.subscribe":
            guard let eventTypes = params["eventTypes"] as? [String],
                  eventTypes.contains("script:state") else { return nil }
            return ["subscriptionId": UUID().uuidString]
        default:
            return nil
        }
    }

    /// Separate entry point keeps the launch fixture testable without process arguments.
    static func scriptResponse(for method: String, params: [String: Any]) -> Any? {
        guard let workspaceId = params["workspaceId"] as? String else { return nil }
        let scriptId = params["scriptId"] as? String ?? ""
        switch method {
        case "script.list":
            let definitions = [
                ("demo-server", "Web server", "npm run dev", "service"),
                ("demo-check", "Check project", "npm run check", "command")
            ]
            return [
                "scripts": definitions.map { id, name, command, mode in
                    [
                        "id": id, "workspaceId": workspaceId, "name": name, "command": command, "mode": mode,
                        "runtime": scriptRuntimes[workspaceId]?[id] ?? ["status": "idle", "restartCount": 0]
                    ] as [String: Any]
                }
            ]
        case "script.start":
            guard ["demo-server", "demo-check"].contains(scriptId) else { return ["ok": false] }
            let runtime: [String: Any] = scriptId == "demo-server"
                ? ["status": "running", "detectedUrl": "http://localhost:4321", "restartCount": 0]
                : ["status": "exited", "exitCode": 0, "restartCount": 0]
            scriptRuntimes[workspaceId, default: [:]][scriptId] = runtime
            return ["ok": true, "scriptId": scriptId]
        case "script.status":
            return scriptRuntimes[workspaceId]?[scriptId] ?? ["status": "idle", "restartCount": 0]
        default:
            return nil
        }
    }
}
