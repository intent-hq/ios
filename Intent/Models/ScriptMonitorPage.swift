import Foundation

nonisolated struct ScriptMonitorPage: Equatable, Sendable {
    let monitors: [ScriptMonitorSummary]
    let nextCursor: String?
}

nonisolated extension ScriptMonitorPage {
    init(_ value: Any, workspaceId: String) throws {
        guard let row = value as? [String: Any] else { throw ScriptMonitorReadError.invalidResponse }
        guard row["view"] as? String == "summary" else { throw ScriptMonitorReadError.unsupportedView }
        guard let values = row["monitors"] as? [Any] else { throw ScriptMonitorReadError.invalidResponse }
        monitors = try values.map { try ScriptMonitorSummary($0, workspaceId: workspaceId) }
        if let raw = row["nextCursor"] {
            guard let cursor = raw as? String, !cursor.isEmpty else { throw ScriptMonitorReadError.invalidResponse }
            nextCursor = cursor
        } else {
            nextCursor = nil
        }
    }
}

nonisolated enum ScriptMonitorReadError: LocalizedError, Equatable {
    case invalidResponse
    case unsupportedView

    var errorDescription: String? {
        switch self {
        case .invalidResponse: "The host returned an unexpected script watch response. Please retry."
        case .unsupportedView: "This host does not support script watch summaries. Reconnect after updating the host."
        }
    }
}
