import Foundation

extension WorkspaceScriptMonitorsStore {
    static let terminalEvents: Set<String> = [
        "scriptMonitor:completed", "scriptMonitor:expired", "scriptMonitor:triggered", "scriptMonitor:cancelled"
    ]

    static func identity(_ data: [String: Any]) -> String? {
        guard let id = data["monitorId"] as? String, let run = data["runId"] as? String else { return nil }
        return "\(id.utf8.count):\(id)\(run)"
    }

    static func normalizeEvent(_ type: String, _ data: [String: Any], _ workspace: String) throws -> [String: Any] {
        guard let row = data["monitor"] as? [String: Any],
              let nestedWorkspace = row["workspaceId"] as? String, nestedWorkspace.utf8.elementsEqual(workspace.utf8),
              let id = row["monitorId"] as? String, !id.isEmpty,
              let run = row["runId"] as? String, !run.isEmpty else { throw ScriptMonitorReadError.invalidResponse }
        var normalized: [String: Any] = ["monitorId": id, "runId": run]
        if terminalEvents.contains(type) { return normalized }
        guard type == "scriptMonitor:registered" else { throw ScriptMonitorReadError.invalidResponse }
        // Events contain full snapshots. Reduce immediately to bounded summary metadata.
        let detail = try ScriptMonitorDetail(row, workspaceId: workspace, monitorId: id)
        normalized["summary"] = detail.summary
        return normalized
    }

    static func fold(_ rows: [ScriptMonitorSummary], _ type: String, _ data: [String: Any]) -> (rows: [ScriptMonitorSummary], needsRefetch: Bool) {
        if terminalEvents.contains(type) {
            return (rows.filter { $0.monitorId != data["monitorId"] as? String || $0.runId != data["runId"] as? String }, false)
        }
        guard let summary = data["summary"] as? ScriptMonitorSummary else { return (rows, true) }
        return (merge(rows, [summary]), false)
    }

    static func merge(_ existing: [ScriptMonitorSummary], _ incoming: [ScriptMonitorSummary]) -> [ScriptMonitorSummary] {
        var indexed = Dictionary(existing.map { ($0.monitorId, $0) }) { _, last in last }
        for row in incoming { indexed[row.monitorId] = row }
        return indexed.values.sorted { left, right in
            if !left.createdAt.utf8.elementsEqual(right.createdAt.utf8) {
                return right.createdAt.utf8.lexicographicallyPrecedes(left.createdAt.utf8)
            }
            return right.monitorId.utf8.lexicographicallyPrecedes(left.monitorId.utf8)
        }
    }
}
