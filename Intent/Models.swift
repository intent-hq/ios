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

/// A saved daemon connection: pairing info plus its API token and metadata.
struct StoredConnection: Codable, Identifiable, Equatable {
    let id: UUID
    var server: PairedServer
    var token: String
    /// Daemon hostname when known, else first host:port.
    var displayName: String
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        server: PairedServer,
        token: String,
        displayName: String? = nil,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.server = server
        self.token = token
        self.displayName = displayName ?? StoredConnection.fallbackDisplayName(for: server)
        self.lastConnectedAt = lastConnectedAt
    }

    static func fallbackDisplayName(for server: PairedServer) -> String {
        if let host = server.hosts.first {
            return "\(host):\(server.port)"
        }
        return server.name
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
    let displayStatus: String? // BE-owned wire value (snake_case, e.g. "pr_open"); nil on older daemons
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

/// A model available for the agent.
struct ModelInfo: Identifiable {
    let id: String       // model id (e.g. "sonnet4.5")
    let name: String     // display name (e.g. "sonnet4.5 (balanced)")
    let provider: String // provider id (e.g. "auggie")
    var isDefault: Bool = false // provider-reported default model (models.list)
}

/// An agent provider from `host.providerAuthStatus` (PROTOCOL §5.14).
struct ProviderInfo: Identifiable, Equatable {
    let id: String
    /// Tri-state: true (signed in), false (signed out), nil (unknown — probe failed or not installed).
    let authenticated: Bool?

    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    var isSelectable: Bool { authenticated != false }

    var displayName: String { ProviderInfo.displayName(for: id) }

    static func displayName(for id: String) -> String {
        switch id {
        case "auggie": return "Auggie"
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case "opencode": return "OpenCode"
        case "droid": return "Droid"
        case "grok": return "Grok"
        case "pi": return "Pi"
        default: return id.capitalized
        }
    }
}

extension Array where Element == ProviderInfo {
    /// True when the daemon returned providers but none can be selected (all
    /// signed out). The pickers show desktop-setup guidance instead of an
    /// empty-value menu in that state (monorepo#985).
    var noneSelectable: Bool {
        !isEmpty && !contains(where: { $0.isSelectable })
    }
}

