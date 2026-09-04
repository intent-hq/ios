import Foundation
import Observation

@MainActor
@Observable class AgentListViewModel {
    var agents: [AgentSession] = []

    var foregroundAgents: [AgentSession] {
        agents.filter { !$0.isBackground && $0.createdByAgentId == nil }
            .sorted { a, b in
                // Agents needing the user first (blocker, question, discussion)
                let rankA = Self.attentionRank(a)
                let rankB = Self.attentionRank(b)
                if rankA != rankB { return rankA < rankB }
                // Then coordinator (spec-writer) first
                if a.specialist == "spec-writer" && b.specialist != "spec-writer" { return true }
                if a.specialist != "spec-writer" && b.specialist == "spec-writer" { return false }
                // Then by last activity (most recent first)
                return Self.byLastActivity(a, b)
            }
    }

    func delegatedAgents(for parentId: String) -> [AgentSession] {
        agents.filter { $0.createdByAgentId == parentId }
            .sorted(by: Self.byAttentionThenLastActivity)
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
        .sorted(by: Self.byAttentionThenLastActivity)
    }

    /// Sort rank for agents whose avatar state `needsUser`: blocker (0),
    /// question (1), discussion (2); every other state ranks last (3), mirroring
    /// the cloudlands hover card that groups attention rows above the rest.
    private static func attentionRank(_ agent: AgentSession) -> Int {
        let state = AgentAvatarState.state(for: agent)
        guard state.needsUser else { return 3 }
        switch state {
        case .attentionBlocker: return 0
        case .question: return 1
        default: return 2
        }
    }

    /// Floats agents needing the user first, then falls back to `byLastActivity`.
    private static func byAttentionThenLastActivity(_ a: AgentSession, _ b: AgentSession) -> Bool {
        let rankA = attentionRank(a)
        let rankB = attentionRank(b)
        if rankA != rankB { return rankA < rankB }
        return byLastActivity(a, b)
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

