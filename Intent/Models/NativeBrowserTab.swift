import Foundation

struct NativeBrowserTab: Codable {
    let id: String
    let workspaceId: String
    var ownerAgentId: String?
    var requestedURL: String
    var url: String
    var title: String
    var loadURL: String?
    var visible = false
    var displayed = false

    var browser: WorkspaceBrowser {
        WorkspaceBrowser(id: id, workspaceId: workspaceId, title: title, url: loadURL ?? requestedURL, command: nil)
    }

    static func matches(_ lhs: String, _ rhs: String) -> Bool {
        func canonical(_ raw: String) -> URLComponents? {
            guard let normalized = try? WorkspaceBrowserURL.normalize(raw),
                  var url = URLComponents(string: normalized) else { return nil }
            if url.path.isEmpty { url.path = "/" }
            return url
        }
        guard let left = canonical(lhs), let right = canonical(rhs) else { return false }
        return left == right
    }

    var report: [String: Any] {
        var value: [String: Any] = [
            "tabId": id, "workspaceId": workspaceId, "url": url, "requestedUrl": requestedURL,
            "title": title, "visibility": visible ? "visible" : "hidden", "displayed": displayed,
            "navigationOnly": true
        ]
        if let ownerAgentId { value["ownerAgentId"] = ownerAgentId }
        return value
    }
}

struct NativeBrowserFailure: Error {
    let code: String
    let message: String
    var ownerAgentId: String?

    func envelope(action: String) -> [String: Any] {
        var value: [String: Any] = ["action": action, "success": false, "error": message, "errorCode": code]
        if let ownerAgentId { value["ownerAgentId"] = ownerAgentId }
        return value
    }
}
