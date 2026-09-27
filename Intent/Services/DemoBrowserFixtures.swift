import Foundation

enum DemoBrowserFixtures {
    static func response(for method: String, params: [String: Any]) -> Any? {
        switch method {
        case "script.list":
            if ProcessInfo.processInfo.arguments.contains("--demo-browsers"),
               let workspaceId = params["workspaceId"] as? String {
                return ["scripts": [[
                    "id": "preview", "workspaceId": workspaceId, "name": "Web preview",
                    "command": "npm run dev",
                    "runtime": ["status": "running", "detectedUrl": "http://localhost:5173", "restartCount": 0]
                ] as [String: Any]]]
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
