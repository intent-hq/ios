import Foundation

/// A scope-aware in-memory agent.list endpoint shared by ordinary demos and
/// the grouping scenario. Counts always describe the whole workspace.
enum DemoAgentListFixtures {
    static func response(rows: [[String: Any]], params: [String: Any]) -> [String: Any] {
        let canonical = rows.map { wire -> [String: Any] in
            var row = wire
            if let agent = AgentSession.parseAgent(wire), let parent = AgentListViewModel.parent(of: agent) {
                row["parentAgentId"] = parent
            }
            return row
        }
        let active = canonical.filter { $0["retiredAt"] == nil }
        let retired = canonical.filter { $0["retiredAt"] != nil }
        let liveIds = Set(active.compactMap { $0["id"] as? String })
        let delegated = active.filter { parent($0) != nil }
        let topLevel = active.filter { parent($0) == nil && !background($0) }
        let standalone = active.filter { parent($0) == nil && background($0) }
        let orphaned = delegated.filter { !liveIds.contains(parent($0) ?? "") }
        let byParent = Dictionary(grouping: delegated) { parent($0) ?? "" }.mapValues(count)
        let selected: [[String: Any]]
        if params["retiredOnly"] as? Bool == true {
            selected = retired
        } else {
            switch params["scope"] as? String {
            case "topLevel": selected = topLevel
            case "background": selected = standalone
            case "delegated":
                if params["orphanedOnly"] as? Bool == true {
                    selected = orphaned
                } else if let parentId = params["parentAgentId"] as? String {
                    selected = delegated.filter { parent($0) == parentId }
                } else {
                    selected = delegated
                }
            default: selected = active
            }
        }
        return [
            "agents": selected, "retiredCount": retired.count,
            "scopeCounts": ["topLevel": topLevel.count, "background": standalone.count, "delegated": delegated.count],
            "delegatedCounts": ["running": count(delegated)["running"] ?? 0, "byParent": byParent, "orphaned": count(orphaned)]
        ]
    }

    private static func parent(_ row: [String: Any]) -> String? { row["parentAgentId"] as? String }

    private static func background(_ row: [String: Any]) -> Bool {
        (row["metadata"] as? [String: Any])?["isBackground"] as? Bool == true
    }

    private static func count(_ rows: [[String: Any]]) -> [String: Int] {
        ["total": rows.count, "running": rows.compactMap(AgentSession.parseAgent).count { AgentAvatarState.state(for: $0) == .running }]
    }

    static var groupRows: [[String: Any]] {
        [
            row("groups-parent", name: "Coordinator"),
            row("groups-child", name: "Direct child", parent: "groups-parent", background: true),
            row("groups-grandchild", name: "Nested child", parent: "groups-child"),
            row("groups-background", name: "Background parent", background: true),
            row("groups-background-child", name: "Background child", parent: "groups-background"),
            row("groups-orphan", name: "Orphan parent", parent: "deleted-parent"),
            row("groups-orphan-child", name: "Orphan child", parent: "groups-orphan"),
            row("groups-retired-child", name: "Retired parent's child", parent: "groups-retired"),
            row("groups-retired", name: "Retired parent", retired: true)
        ]
    }

    private static func row(
        _ id: String, name: String, parent: String? = nil, background: Bool = false, retired: Bool = false
    ) -> [String: Any] {
        var row: [String: Any] = ["id": id, "name": name, "status": "idle", "metadata": ["isBackground": background]]
        if let parent { row["parentAgentId"] = parent }
        if retired { row["retiredAt"] = "2026-09-30T00:00:00Z" }
        return row
    }
}
