import Foundation

nonisolated struct WorkspaceScript: Equatable, Identifiable, Sendable {
    let id: String
    let workspaceId: String
    let name: String
    let command: String
    var status: String = "idle"
    var detectedURL: String?
    var error: String?

    var isActive: Bool { status != "idle" && status != "exited" }

    init(id: String, workspaceId: String, name: String, command: String, status: String = "idle", detectedURL: String? = nil, error: String? = nil) {
        self.id = id
        self.workspaceId = workspaceId
        self.name = name
        self.command = command
        self.status = status
        self.detectedURL = detectedURL
        self.error = error
    }

    init?(definition: [String: Any], workspaceId: String) {
        guard let id = definition["id"] as? String, !id.isEmpty,
              definition["workspaceId"] as? String == workspaceId,
              let name = definition["name"] as? String,
              let command = definition["command"] as? String else { return nil }
        self.init(id: id, workspaceId: workspaceId, name: name, command: command)
        if let runtime = definition["runtime"] as? [String: Any] { apply(runtime: runtime) }
    }

    mutating func apply(runtime: [String: Any]) {
        status = runtime["status"] as? String ?? "idle"
        // Runtime snapshots omit cleared fields; absence must clear the old run.
        detectedURL = runtime["detectedUrl"] as? String
        error = runtime["error"] as? String
    }

    var browser: WorkspaceBrowser? {
        guard status == "running", let detectedURL,
              let url = try? WorkspaceBrowserURL.normalize(detectedURL) else { return nil }
        return WorkspaceBrowser(
            id: "script:\(id)",
            workspaceId: workspaceId,
            title: name.isEmpty ? url : name,
            url: url,
            command: command
        )
    }
}

nonisolated enum WorkspaceScriptError: LocalizedError {
    case invalidResponse

    var errorDescription: String? { "The server returned an unexpected script response." }
}
