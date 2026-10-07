import Foundation

/// Rebuild once per agent snapshot, not once per rendered row.
struct AgentListIndex {
    let active: [AgentSession]
    let foregroundOrder: [AgentSession]
    let byID: [String: AgentSession]
    let children: [String: [AgentSession]]

    init(agents: [AgentSession]) {
        let ranked = agents.filter { $0.retiredAt == nil }.map(RankedAgent.init)
        active = ranked.sorted { $0.precedes($1, coordinatorFirst: false) }.map(\.agent)
        foregroundOrder = ranked.sorted { $0.precedes($1, coordinatorFirst: true) }.map(\.agent)
        var byID: [String: AgentSession] = [:]
        var children: [String: [AgentSession]] = [:]
        for agent in active {
            byID[agent.id] = agent
            if let parent = AgentListViewModel.parent(of: agent) {
                children[parent, default: []].append(agent)
            }
        }
        self.byID = byID
        self.children = children
    }

    private struct RankedAgent {
        let agent: AgentSession
        let attention: Int
        let activity: Date?

        init(_ agent: AgentSession) {
            self.agent = agent
            attention = AgentListViewModel.attentionRank(agent)
            activity = ISO8601DateFormatter.lenientDate(from: agent.bestTimestamp)
        }

        func precedes(_ other: Self, coordinatorFirst: Bool) -> Bool {
            if attention != other.attention { return attention < other.attention }
            if coordinatorFirst, (agent.specialist == "spec-writer") != (other.agent.specialist == "spec-writer") {
                return agent.specialist == "spec-writer"
            }
            switch (activity, other.activity) {
            case let (first?, second?) where first != second: return first > second
            case (.some, nil): return true
            case (nil, .some): return false
            default: return agent.id < other.agent.id
            }
        }
    }
}
