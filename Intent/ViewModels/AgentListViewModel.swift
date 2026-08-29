import Foundation
import Observation

@MainActor
@Observable class AgentListViewModel {
    var agents: [AgentSession] = []

    var foregroundAgents: [AgentSession] {
        agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
            .sorted { a, b in
                // Coordinator (spec-writer) first
                if a.specialist == "spec-writer" && b.specialist != "spec-writer" { return true }
                if a.specialist != "spec-writer" && b.specialist == "spec-writer" { return false }
                // Then by last activity (most recent first)
                return Self.byLastActivity(a, b)
            }
    }

    func delegatedAgents(for parentId: String) -> [AgentSession] {
        agents.filter { $0.createdByAgentId == parentId }
            .sorted(by: Self.byLastActivity)
    }

    var standaloneBackgroundAgents: [AgentSession] {
        let foregroundIds = Set(foregroundAgents.map { $0.id })
        let existingAgentIds = Set(agents.map { $0.id })
        let delegatedIds = Set(agents.filter {
            guard let parentId = $0.createdByAgentId else { return false }
            return existingAgentIds.contains(parentId)
        }.map { $0.id })
        return agents.filter {
            $0.isBackground &&
            !foregroundIds.contains($0.id) &&
            !delegatedIds.contains($0.id) &&
            ($0.createdByAgentId == nil || !existingAgentIds.contains($0.createdByAgentId!))
        }
        .sorted(by: Self.byLastActivity)
    }

    /// Orders agents by `bestTimestamp` descending (most recent first),
    /// parsing timestamps leniently since the daemon emits both fractional-
    /// and whole-second RFC-3339 forms (which string comparison misorders).
    /// Agents with no parseable timestamp sort last, with id as a stable
    /// tiebreak.
    private static func byLastActivity(_ a: AgentSession, _ b: AgentSession) -> Bool {
        let dateA = ISO8601DateFormatter.lenientDate(from: a.bestTimestamp)
        let dateB = ISO8601DateFormatter.lenientDate(from: b.bestTimestamp)
        switch (dateA, dateB) {
        case let (ta?, tb?) where ta != tb:
            return ta > tb
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return a.id < b.id
        }
    }
}

