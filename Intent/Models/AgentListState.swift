import Foundation
import Observation

/// A lazy section of the workspace list. Orphaned falls back to the whole
/// delegated bin when the daemon omits delegatedCounts.orphaned.
enum AgentListGroup: Hashable {
    case background
    case delegated(parentId: String)
    case orphaned
    case retired
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
    /// Absence means the orphan-only read is unsupported; zero is supported.
    let orphaned: Count?

    init?(wire: [String: Any]) {
        guard let running = wire["running"] as? Int,
              let byParent = wire["byParent"] as? [String: [String: Any]] else { return nil }
        self.running = running
        self.byParent = byParent.compactMapValues { Count(wire: $0) }
        orphaned = Count(wire: wire["orphaned"] as? [String: Any] ?? [:])
    }
}

/// Display state and request bookkeeping for one workspace. No transcript or
/// detail cache lives here: all list reads seed AgentSummaryStore separately.
@MainActor @Observable
final class AgentListState {
    var retiredAgents: [AgentSession] = []
    var retiredCount = 0
    var scopeCounts: AgentScopeCounts?
    var delegatedCounts: AgentDelegatedCounts?
    var loadedGroups: Set<AgentListGroup> = []
    var loadingGroups: Set<AgentListGroup> = []
    var errors: [AgentListGroup: String] = [:]
    /// Authoritative membership from orphanedOnly, never guessed from an
    /// incomplete cache (background parents may not have been loaded yet).
    var orphanedAgentIds: Set<String> = []

    @ObservationIgnored var epoch = UUID()
    @ObservationIgnored var sequence = 0
    @ObservationIgnored var metadataSequence = 0
    @ObservationIgnored var topLevelRequest = 0
    @ObservationIgnored var groupRequests: [AgentListGroup: Int] = [:]
    @ObservationIgnored var requestedGroups: Set<AgentListGroup> = []
    @ObservationIgnored var members: [AgentListGroup: Set<String>] = [:]
    @ObservationIgnored var rowSequences: [String: Int] = [:]

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
