import Foundation

struct WatchedAgentGroup {
    let id: String?
    let expectedAgentIds: Set<String>
    let completedAgentIds: Set<String>
    let deletedAgentIds: Set<String>

    init(_ values: [String: Any]) {
        id = values["groupId"] as? String
        expectedAgentIds = Set(values["expectedAgentIds"] as? [String] ?? [])
        completedAgentIds = Set(values["completedAgentIds"] as? [String] ?? [])
        deletedAgentIds = Set(values["deletedAgentIds"] as? [String] ?? [])
    }
}

struct WatchedAgentRow: Identifiable {
    let agent: AgentSession
    let workspaceId: String?
    let hasSummary: Bool
    let isCompleted: Bool
    let isDeleted: Bool
    var id: String { agent.id }
    var statusKnown: Bool { agent.status != "unknown" }

    var statusText: String {
        if isDeleted { return "Deleted" }
        if isCompleted { return "Completed" }
        if !statusKnown { return "Status unknown" }
        if agent.isErrored { return "Error" }
        if agent.isActive { return "Working..." }
        return agent.status.capitalized
    }
}
