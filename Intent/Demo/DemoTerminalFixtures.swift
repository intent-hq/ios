#if DEBUG
import Foundation

enum DemoTerminalFixtures {
    private static var terminals: [String: String] = [:]
    private static let bootId = UUID().uuidString
    // A steady cursor lets UI automation reach idle while preserving real keyboard interactions.
    private static let buffer = "\u{1b}[2 qDemo workspace terminal\r\n$ "

    static func response(for method: String, params: [String: Any]) -> Any? {
        let workspaceId = params["workspaceId"] as? String ?? ""
        let terminalId = params["terminalId"] as? String ?? ""
        switch method {
        case "terminal.create":
            let id = UUID().uuidString
            terminals[id] = workspaceId
            return ["terminalId": id]
        case "terminal.list":
            return [
                "daemonBootId": bootId,
                "terminals": terminals.filter { $0.value == workspaceId }.map { terminal in
                    ["id": terminal.key, "name": "Terminal", "cwd": "/workspace", "isExecutingCommand": true] as [String: Any]
                }
            ]
        case "terminal.getBuffer":
            return ["terminalId": terminalId, "data": Data(buffer.utf8).base64EncodedString()]
        case "terminal.write", "terminal.resize":
            return ["ok": true]
        case "terminal.kill":
            terminals.removeValue(forKey: terminalId)
            return ["ok": true]
        case "events.subscribe":
            guard let group = params["replaceGroup"] as? String,
                  group.hasPrefix("ios-terminal-") || group == "ios-mobile-terminals" else { return nil }
            return ["subscriptionId": UUID().uuidString]
        default:
            return nil
        }
    }
}
#endif
