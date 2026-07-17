import Foundation

struct PairedServer: Codable, Equatable {
    let hosts: [String]
    let port: Int
    let name: String
    let pairedAt: Date
    let certFingerprint: String?

    init(hosts: [String], port: Int, name: String, pairedAt: Date, certFingerprint: String? = nil) {
        self.hosts = hosts
        self.port = port
        self.name = name
        self.pairedAt = pairedAt
        self.certFingerprint = certFingerprint
    }
}

struct WorkspaceAgentInfo: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let specialist: String?
    let lastActivity: String?
    let isStreaming: Bool
    let isResponding: Bool
}

struct Workspace: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let branch: String?
    let baseRef: String?
    let status: String?
    let activity: String?      // "idle" | "agent_running" from daemon
    let lastActivity: String?
    let updatedAt: String?
    let repositoryOwner: String?
    let repositoryName: String?
    let prStatus: String?      // "Open", "Closed", "Merged", "Draft"
    let prNumber: Int?
    let diffSummaryTotalFiles: Int?  // from diffSummary.totalFiles
    let taskStatsTotal: Int?         // from taskStats.total
    let taskStatsCompleted: Int?     // from taskStats.completed
    let taskStatsInProgress: Int?    // from taskStats.inProgress
    let agentSummaryCount: Int?
    let agentSummaryAgents: [WorkspaceAgentInfo]?
}

struct KnownRepo: Identifiable {
    let path: String
    let name: String
    let owner: String?
    let addedAt: String?
    let lastUsedAt: String?
    var id: String { path }
}

