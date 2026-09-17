import Foundation
import Observation

@MainActor
@Observable class AgentListViewModel {
    private static let noAttentionRank = 3

    var agents: [AgentSession] = []

    var foregroundAgents: [AgentSession] {
        agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
            .sorted { firstAgent, secondAgent in
                // Agents needing the user first (blocker, question, discussion)
                let rankA = Self.attentionRank(firstAgent)
                let rankB = Self.attentionRank(secondAgent)
                if rankA != rankB { return rankA < rankB }
                // Then coordinator (spec-writer) first
                if firstAgent.specialist == "spec-writer", secondAgent.specialist != "spec-writer" { return true }
                if firstAgent.specialist != "spec-writer", secondAgent.specialist == "spec-writer" { return false }
                // Then by last activity (most recent first)
                return Self.byLastActivity(firstAgent, secondAgent)
            }
    }

    func delegatedAgents(for parentId: String) -> [AgentSession] {
        agents.filter { $0.createdByAgentId == parentId }
            .sorted(by: Self.byAttentionThenLastActivity)
    }

    var standaloneBackgroundAgents: [AgentSession] {
        let foregroundIds = Set(foregroundAgents.map { $0.id })
        let existingAgentIds = Set(agents.map { $0.id })
        let delegatedIds = Set(agents.filter { agent in
            guard let parentId = agent.createdByAgentId else { return false }
            return existingAgentIds.contains(parentId)
        }
        .map { agent in agent.id })
        return agents.filter { agent in
            guard agent.isBackground,
                  !foregroundIds.contains(agent.id),
                  !delegatedIds.contains(agent.id)
            else { return false }
            guard let parentId = agent.createdByAgentId else { return true }
            return !existingAgentIds.contains(parentId)
        }
        .sorted(by: Self.byAttentionThenLastActivity)
    }

    /// Sort rank for agents whose avatar state `needsUser`: blocker (0),
    /// question (1), discussion (2); every other state ranks last (3), mirroring
    /// the cloudlands hover card that groups attention rows above the rest.
    private static func attentionRank(_ agent: AgentSession) -> Int {
        let state = AgentAvatarState.state(for: agent)
        guard state.needsUser else { return Self.noAttentionRank }
        switch state {
        case .attentionBlocker: return 0
        case .question: return 1
        default: return 2
        }
    }

    /// Floats agents needing the user first, then falls back to `byLastActivity`.
    private static func byAttentionThenLastActivity(_ firstAgent: AgentSession, _ secondAgent: AgentSession) -> Bool {
        let rankA = attentionRank(firstAgent)
        let rankB = attentionRank(secondAgent)
        if rankA != rankB { return rankA < rankB }
        return byLastActivity(firstAgent, secondAgent)
    }

    /// Orders agents by `bestTimestamp` descending (most recent first),
    /// parsing timestamps leniently since the daemon emits both fractional-
    /// and whole-second RFC-3339 forms (which string comparison misorders).
    /// Agents with no parseable timestamp sort last, with id as a stable
    /// tiebreak.
    private static func byLastActivity(_ firstAgent: AgentSession, _ secondAgent: AgentSession) -> Bool {
        let dateA = ISO8601DateFormatter.lenientDate(from: firstAgent.bestTimestamp)
        let dateB = ISO8601DateFormatter.lenientDate(from: secondAgent.bestTimestamp)
        switch (dateA, dateB) {
        case let (firstTimestamp?, secondTimestamp?) where firstTimestamp != secondTimestamp:
            return firstTimestamp > secondTimestamp
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        default:
            return firstAgent.id < secondAgent.id
        }
    }
}
