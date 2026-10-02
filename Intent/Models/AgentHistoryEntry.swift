import Foundation

/// One visited agent conversation, keyed by its saved connection and agent.
nonisolated struct AgentHistoryEntry: Codable, Equatable, Identifiable, Sendable {
    let connectionId: UUID
    let workspaceId: String
    var workspaceTitle: String?
    let agentId: String
    var agentName: String
    var visitedAt: Date

    var id: String { "\(connectionId.uuidString)/\(agentId)" }
}

nonisolated enum AgentHistory {
    static let maximumEntries = 30

    /// Moves the visit to the front. A visit made before the workspace list
    /// loaded keeps the title recorded on an earlier visit.
    static func recording(
        _ visit: AgentHistoryEntry,
        in entries: [AgentHistoryEntry],
        limit: Int = Self.maximumEntries
    ) -> [AgentHistoryEntry] {
        var visit = visit
        if visit.workspaceTitle == nil {
            visit.workspaceTitle = entries.first { $0.id == visit.id }?.workspaceTitle
        }
        let others = entries.filter { $0.id != visit.id }
        return Array(([visit] + others).prefix(limit))
    }

    /// Drops one device's entries for a workspace it reported deleted or archived.
    static func removing(
        workspaceId: String,
        on connectionId: UUID,
        from entries: [AgentHistoryEntry]
    ) -> [AgentHistoryEntry] {
        entries.filter { $0.connectionId != connectionId || $0.workspaceId != workspaceId }
    }

    /// Entries whose connection is still saved; forgotten devices drop out.
    static func visible(_ entries: [AgentHistoryEntry], savedConnectionIDs: Set<UUID>) -> [AgentHistoryEntry] {
        entries.filter { savedConnectionIDs.contains($0.connectionId) }
    }
}
