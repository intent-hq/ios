#if DEBUG
import Foundation

enum DemoBrowserFixtures {
    private static let scrollScriptCount = 10
    private static var scriptRuntimes: [String: [String: [String: Any]]] = [:]
    private static var removedScripts: [String: Set<String>] = [:]

    // Nil keeps the ordinary demo transcript when this scenario was not requested.
    static var conversationMessages: [[String: Any]]? { // swiftlint:disable:this discouraged_optional_collection
        guard LaunchOptions.current.contains("--demo-browsers") else { return nil }
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
        if LaunchOptions.current.contains("--demo-repo-scripts"),
           let response = DemoRepositoryScriptFixtures.response(for: method, params: params) { return response }
        if LaunchOptions.current.contains("--demo-scripts"),
           let response = scriptResponse(
               for: method,
               params: params,
               longList: LaunchOptions.current.contains("--demo-long-script-list")
           ) { return response }
        switch method {
        case "browser.syncTabs":
            return ["drop": [String]()]
        case "browser.listTabs":
            if LaunchOptions.current.contains("--demo-browsers"),
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
            if LaunchOptions.current.contains("--demo-browsers"),
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
    static func scriptResponse(for method: String, params: [String: Any], longList: Bool = false) -> Any? {
        guard let workspaceId = params["workspaceId"] as? String else { return nil }
        let scriptId = params["scriptId"] as? String ?? ""
        var definitions = [
            ("demo-server", "Web server", "npm run dev", "service"),
            ("demo-check", "Check project", "npm run check", "command")
        ]
        if longList {
            definitions += (0..<scrollScriptCount).map { index in
                ("demo-scroll-script-\(index)", "Completed check \(index + 1)", "echo checked", "command")
            }
        }
        switch method {
        case "script.list":
            return [
                "scripts": definitions.filter { !removedScripts[workspaceId, default: []].contains($0.0) }.map { id, name, command, mode in
                    [
                        "id": id, "workspaceId": workspaceId, "name": name, "command": command, "mode": mode,
                        "runtime": scriptRuntimes[workspaceId]?[id] ?? initialRuntime(scriptId: id, longList: longList)
                    ] as [String: Any]
                }
            ]
        case "script.start":
            guard definitions.contains(where: { $0.0 == scriptId }) else { return ["ok": false] }
            let runtime: [String: Any] = scriptId == "demo-server"
                ? ["status": "running", "detectedUrl": "http://localhost:4321", "restartCount": 0]
                : ["status": "exited", "exitCode": 0, "restartCount": 0]
            scriptRuntimes[workspaceId, default: [:]][scriptId] = runtime
            return ["ok": true, "scriptId": scriptId]
        case "script.status":
            return scriptRuntimes[workspaceId]?[scriptId] ?? initialRuntime(scriptId: scriptId, longList: longList)
        case "script.stop":
            scriptRuntimes[workspaceId, default: [:]][scriptId] = ["status": "exited", "exitCode": 0, "restartCount": 0]
            return ["ok": true, "scriptId": scriptId]
        case "script.remove":
            removedScripts[workspaceId, default: []].insert(scriptId)
            scriptRuntimes[workspaceId]?[scriptId] = nil
            return ["ok": true, "scriptId": scriptId]
        default:
            return nil
        }
    }

    private static func initialRuntime(scriptId: String, longList: Bool) -> [String: Any] {
        // Completed runs make the opt-in rows visible without changing the default demo.
        if longList, scriptId.hasPrefix("demo-scroll-script-") {
            return ["status": "exited", "exitCode": 0, "restartCount": 0]
        }
        return ["status": "idle", "restartCount": 0]
    }
}
#endif
