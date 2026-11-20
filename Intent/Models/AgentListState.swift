import Foundation
import Observation

enum AgentListGroup: Hashable {
    case background
    case delegated(parentId: String)
    case orphaned
    case retired
}

enum AgentListReadScope: Hashable {
    case allActive
    case background
    case delegated(parentId: String?)
    case orphaned
    case retired
    case topLevel

    func contains(_ row: AgentSession) -> Bool {
        if self == .retired { return row.retiredAt != nil }
        guard row.retiredAt == nil else { return false }
        switch self {
        case .allActive: return true
        case .background: return row.parentAgentId == nil && row.isBackground
        case let .delegated(parentId):
            return row.parentAgentId != nil && (parentId == nil || row.parentAgentId == parentId)
        case .topLevel: return row.parentAgentId == nil && !row.isBackground
        case .orphaned, .retired: return false
        }
    }
}

struct AgentScopeCounts: Equatable {
    let topLevel: Int
    let delegated: Int
    let background: Int

    init?(wire: [String: Any]) {
        guard let topLevel = wire["topLevel"] as? Int,
              let delegated = wire["delegated"] as? Int, let background = wire["background"] as? Int else { return nil }
        self.topLevel = topLevel
        self.delegated = delegated
        self.background = background
    }
}

struct AgentDelegatedCounts: Equatable {
    struct Count: Equatable {
        let total: Int
        let running: Int

        init?(wire: [String: Any]) {
            guard let total = wire["total"] as? Int, let running = wire["running"] as? Int else { return nil }
            self.total = total
            self.running = running
        }
    }

    let running: Int
    let byParent: [String: Count]
    let orphaned: Count?

    init?(wire: [String: Any]) {
        guard let running = wire["running"] as? Int,
              let byParent = wire["byParent"] as? [String: [String: Any]] else { return nil }
        self.running = running
        self.byParent = byParent.compactMapValues { Count(wire: $0) }
        orphaned = Count(wire: wire["orphaned"] as? [String: Any] ?? [:])
    }
}

@MainActor @Observable
final class AgentListState {
    var retiredAgents: [AgentSession] = []
    var retiredCount = 0
    var scopeCounts: AgentScopeCounts?
    var delegatedCounts: AgentDelegatedCounts?
    var loadedGroups: Set<AgentListGroup> = []
    var loadingGroups: Set<AgentListGroup> = []
    var errors: [AgentListGroup: String] = [:]
    var orphanedAgentIds: Set<String> = []

    @ObservationIgnored var epoch = UUID()
    @ObservationIgnored var sequence = 0
    @ObservationIgnored var metadataSequence = 0
    @ObservationIgnored var topLevelRequest = 0
    @ObservationIgnored var groupRequests: [AgentListGroup: Int] = [:]
    @ObservationIgnored var requestedGroups: Set<AgentListGroup> = []
    @ObservationIgnored var members: [AgentListGroup: Set<String>] = [:]
    @ObservationIgnored var rowSequences: [String: Int] = [:]
    @ObservationIgnored var coverage: [AgentListReadScope: Int] = [:]

    func reset() {
        epoch = UUID()
        retiredAgents = []
        retiredCount = 0
        scopeCounts = nil
        delegatedCounts = nil
        loadedGroups = []
        loadingGroups = []
        errors = [:]
        orphanedAgentIds = []
        requestedGroups = []
        groupRequests = [:]
        members = [:]
        rowSequences = [:]
        coverage = [:]
        metadataSequence = 0
        topLevelRequest = 0
    }

    func beginRead() -> Int {
        sequence += 1
        return sequence
    }

    func readMetadata(_ response: [String: Any], sequence: Int) {
        guard sequence >= metadataSequence else { return }
        metadataSequence = sequence
        retiredCount = response["retiredCount"] as? Int ?? 0
        scopeCounts = AgentScopeCounts(wire: response["scopeCounts"] as? [String: Any] ?? [:])
        delegatedCounts = AgentDelegatedCounts(wire: response["delegatedCounts"] as? [String: Any] ?? [:])
        if delegatedCounts?.orphaned == nil { orphanedAgentIds = [] }
    }
}
