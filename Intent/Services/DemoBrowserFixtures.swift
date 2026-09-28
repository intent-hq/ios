import Foundation

enum DemoBrowserFixtures {
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
}
