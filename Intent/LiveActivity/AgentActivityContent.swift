#if os(iOS)
import Foundation

/// Turns workspace rows from every live backend into Live Activity content:
/// only workspaces whose agents are running right now.
enum AgentActivityContent {
    struct Entry {
        let connectionId: UUID
        let workspace: Workspace
    }

    struct Result {
        let state: AgentActivityAttributes.ContentState
        /// Every running workspace, keyed like `AgentActivityRow.id`.
        let runningKeys: Set<String>
    }

    static let maxRows = 3

    static func make(from entries: [Entry], now: Date) -> Result {
        let rows = entries.filter { hasRunningAgents($0.workspace) }.map { entry in
            let workspace = entry.workspace
            let agent = workspace.agentSummaryAgents.first { $0.isStreaming || $0.isResponding }
            return AgentActivityRow(
                connectionId: entry.connectionId,
                workspaceId: workspace.id,
                title: workspace.title,
                detail: workspace.statusMessage.flatMap { $0.isEmpty ? nil : $0 },
                agentId: agent?.id,
                agentName: agent?.name
            )
        }
        return Result(
            state: AgentActivityAttributes.ContentState(
                rows: Array(rows.prefix(maxRows)),
                runningCount: rows.count,
                updatedAt: now.timeIntervalSince1970
            ),
            runningKeys: Set(rows.map(\.id))
        )
    }
}
#endif
