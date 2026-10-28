import Foundation
import Observation

@MainActor
@Observable class AgentListViewModel {
    private static let noAttentionRank = 3

    var agents: [AgentSession] = [] {
        didSet { index = AgentListIndex(agents: agents) }
    }
    private var index = AgentListIndex(agents: [])
    let list: AgentListState
    var expandedGroups: Set<AgentListGroup> = []

    init(list: AgentListState = AgentListState()) { self.list = list }

    /// Matches desktop agentDelegationParentOf: nonempty canonical parent,
    /// then nonempty legacy creator, including when the wire parent is null.
    static func parent(of agent: AgentSession) -> String? {
        if let parent = agent.parentAgentId, !parent.isEmpty { return parent }
        if let creator = agent.createdByAgentId, !creator.isEmpty { return creator }
        return nil
    }

    private var activeAgents: [AgentSession] { index.active }

    private func isRoot(_ agent: AgentSession) -> Bool {
        guard let parent = Self.parent(of: agent) else { return true }
        // Only a complete legacy response can infer a missing parent.
        return list.scopeCounts == nil && index.byID[parent] == nil
    }

    var foregroundAgents: [AgentSession] {
        index.foregroundOrder.filter { !$0.isBackground && isRoot($0) }
    }

    func delegatedAgents(for parentId: String) -> [AgentSession] {
        index.children[parentId] ?? []
    }

    var standaloneBackgroundAgents: [AgentSession] {
        activeAgents.filter { $0.isBackground && isRoot($0) }
    }

    var orphanedAgents: [AgentSession] {
        guard list.scopeCounts != nil else { return [] }
        if list.delegatedCounts?.orphaned != nil {
            return activeAgents.filter { agent in
                guard list.orphanedAgentIds.contains(agent.id), let parent = Self.parent(of: agent) else { return false }
                // A restored parent may arrive while the orphan refresh is
                // pending or failed. Stale membership must not duplicate its
                // children; cache absence alone still never adds an orphan.
                return index.byID[parent] == nil
            }
        }
        // Old scoped daemons return the whole delegated bin. Its roots may
        // have unloaded parents, or background parents in a collapsed bin.
        let hiddenBackground = !expandedGroups.contains(.background)
        return activeAgents.filter { agent in
            guard let parent = Self.parent(of: agent) else { return false }
            guard let parentRow = index.byID[parent] else { return true }
            return hiddenBackground && parentRow.isBackground && Self.parent(of: parentRow) == nil
        }
    }

    func rows(for group: AgentListGroup) -> [AgentSession] {
        switch group {
        case .background: return standaloneBackgroundAgents
        case let .delegated(parentId): return delegatedAgents(for: parentId)
        case .orphaned: return orphanedAgents
        case .retired: return list.retiredAgents.sorted(by: Self.byAttentionThenLastActivity)
        }
    }

    func count(for group: AgentListGroup) -> Int {
        let loaded = rows(for: group).count
        switch group {
        case .background: return max(loaded, list.scopeCounts?.background ?? 0)
        case let .delegated(parentId): return max(loaded, list.delegatedCounts?.byParent[parentId]?.total ?? 0)
        case .orphaned:
            if let orphaned = list.delegatedCounts?.orphaned { return orphaned.total }
            return list.scopeCounts.map { max($0.delegated, activeAgents.count { Self.parent(of: $0) != nil }) } ?? 0
        case .retired: return max(loaded, list.retiredCount)
        }
    }

    func runningCount(for group: AgentListGroup) -> Int {
        switch group {
        case let .delegated(parentId):
            if let count = list.delegatedCounts?.byParent[parentId] { return count.running }
        case .orphaned:
            if let count = list.delegatedCounts?.orphaned { return count.running }
            if let count = list.delegatedCounts { return count.running }
        default: break
        }
        return rows(for: group).count { AgentAvatarState.state(for: $0) == .running }
    }

    var hasAgentSections: Bool {
        !foregroundAgents.isEmpty || !expandedGroups.isEmpty || [.background, .orphaned, .retired].contains { count(for: $0) > 0 }
    }

    func isExpanded(_ group: AgentListGroup) -> Bool {
        if case .delegated = group, list.scopeCounts != nil, list.delegatedCounts?.orphaned == nil,
           expandedGroups.contains(.orphaned) { return !collapsedLegacyParents.contains(group) }
        return expandedGroups.contains(group)
    }

    private var collapsedLegacyParents: Set<AgentListGroup> = []

    func toggle(_ group: AgentListGroup) {
        if case .delegated = group, list.scopeCounts != nil, list.delegatedCounts?.orphaned == nil,
           expandedGroups.contains(.orphaned) {
            if !collapsedLegacyParents.insert(group).inserted { collapsedLegacyParents.remove(group) }
        } else if !expandedGroups.insert(group).inserted { expandedGroups.remove(group) }
    }

    /// Which sections are open, so another list of the same workspace can match it.
    struct Expansion: Equatable {
        var groups: Set<AgentListGroup> = []
        var collapsedLegacyParents: Set<AgentListGroup> = []
    }

    var expansion: Expansion {
        get { Expansion(groups: expandedGroups, collapsedLegacyParents: collapsedLegacyParents) }
        set {
            expandedGroups = newValue.groups
            collapsedLegacyParents = newValue.collapsedLegacyParents
        }
    }

    func reset() {
        agents = []
        expandedGroups = []
        collapsedLegacyParents = []
    }

    struct TreeRow: Identifiable {
        let agent: AgentSession
        let depth: Int
        var id: String { agent.id }
    }

    /// Flatten only expanded branches, preserving ordering and bounding bad
    /// cyclic data without recursive SwiftUI view construction.
    func visibleTree(_ roots: [AgentSession]) -> [TreeRow] {
        var result: [TreeRow] = []
        var visited: Set<String> = []
        var pending = roots.reversed().map { TreeRow(agent: $0, depth: 0) }
        while let row = pending.popLast() {
            guard visited.insert(row.id).inserted else { continue }
            result.append(row)
            if isExpanded(.delegated(parentId: row.id)) {
                pending.append(contentsOf: delegatedAgents(for: row.id).reversed().map { child in
                    TreeRow(agent: child, depth: row.depth + 1)
                })
            }
        }
        return result
    }

    /// Sort rank for agents whose avatar state `needsUser`: blocker (0),
    /// question (1), discussion (2); every other state ranks last (3), mirroring
    /// the cloudlands hover card that groups attention rows above the rest.
    static func attentionRank(_ agent: AgentSession) -> Int {
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
    static func byLastActivity(_ firstAgent: AgentSession, _ secondAgent: AgentSession) -> Bool {
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
