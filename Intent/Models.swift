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

/// One detected PR on a workspace — a lenient subset of PROTOCOL §7.6
/// `PullRequestInfo`. `status` keeps the raw wire string ("Open" / "Closed" /
/// "Merged" / "Draft"; serde enum variant names) so unknown future variants
/// are tolerated; everything but `number`/`status` is optional.
struct WorkspacePullRequest: Codable, Identifiable, Equatable {
    let number: Int
    let status: String
    let title: String?
    let url: String?
    let createdAt: String?
    let updatedAt: String?

    var id: Int { number }

    init(number: Int, status: String, title: String? = nil, url: String? = nil,
         createdAt: String? = nil, updatedAt: String? = nil) {
        self.number = number
        self.status = status
        self.title = title
        self.url = url
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// Failable dict-path parse (JSONSerialization wire shape); rows missing
    /// the required `number`/`status` are dropped by callers via compactMap.
    init?(wire: [String: Any]) {
        guard let number = wire["number"] as? Int,
              let status = wire["status"] as? String else { return nil }
        self.init(
            number: number,
            status: status,
            title: wire["title"] as? String,
            url: wire["url"] as? String,
            createdAt: wire["createdAt"] as? String,
            updatedAt: wire["updatedAt"] as? String
        )
    }
}

struct Workspace: Codable, Identifiable, Equatable {
    let id: String
    let title: String
    let branch: String?
    let baseRef: String?
    let status: String?
    let activity: String?      // "idle" | "agent_running" from daemon
    let displayStatus: String? // BE-owned wire value (snake_case, e.g. "pr_open"); nil on older daemons
    let attention: String?     // "none" | "unread" | "review_required"; nil on older daemons
    let waiting: Bool          // orthogonal waiting flag (protocol 6.17); omitted on the wire when false
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
    let pullRequests: [WorkspacePullRequest]?  // detected-PR pool (§5.1); nil on older daemons
    let activePullRequest: WorkspacePullRequest?  // single active PR (§5.1); nil when absent

    /// Explicit initializer so `attention` / `waiting` / `pullRequests` /
    /// `activePullRequest` can default — existing call sites (and test
    /// fixtures) that predate the fields stay valid.
    init(id: String, title: String, branch: String?, baseRef: String?, status: String?,
         activity: String?, displayStatus: String?, attention: String? = nil,
         waiting: Bool = false,
         lastActivity: String?, updatedAt: String?, repositoryOwner: String?,
         repositoryName: String?, prStatus: String?, prNumber: Int?,
         diffSummaryTotalFiles: Int?, taskStatsTotal: Int?, taskStatsCompleted: Int?,
         taskStatsInProgress: Int?, agentSummaryCount: Int?,
         agentSummaryAgents: [WorkspaceAgentInfo]?,
         pullRequests: [WorkspacePullRequest]? = nil,
         activePullRequest: WorkspacePullRequest? = nil) {
        self.id = id
        self.title = title
        self.branch = branch
        self.baseRef = baseRef
        self.status = status
        self.activity = activity
        self.displayStatus = displayStatus
        self.attention = attention
        self.waiting = waiting
        self.lastActivity = lastActivity
        self.updatedAt = updatedAt
        self.repositoryOwner = repositoryOwner
        self.repositoryName = repositoryName
        self.prStatus = prStatus
        self.prNumber = prNumber
        self.diffSummaryTotalFiles = diffSummaryTotalFiles
        self.taskStatsTotal = taskStatsTotal
        self.taskStatsCompleted = taskStatsCompleted
        self.taskStatsInProgress = taskStatsInProgress
        self.agentSummaryCount = agentSummaryCount
        self.agentSummaryAgents = agentSummaryAgents
        self.pullRequests = pullRequests
        self.activePullRequest = activePullRequest
    }

    /// Custom decode so `waiting` honors the wire contract (PROTOCOL §5.1:
    /// omitted when false) — the synthesized decoder would throw keyNotFound
    /// on the common not-waiting shape if a JSONDecoder path is ever added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        branch = try c.decodeIfPresent(String.self, forKey: .branch)
        baseRef = try c.decodeIfPresent(String.self, forKey: .baseRef)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        activity = try c.decodeIfPresent(String.self, forKey: .activity)
        displayStatus = try c.decodeIfPresent(String.self, forKey: .displayStatus)
        attention = try c.decodeIfPresent(String.self, forKey: .attention)
        waiting = try c.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        lastActivity = try c.decodeIfPresent(String.self, forKey: .lastActivity)
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt)
        repositoryOwner = try c.decodeIfPresent(String.self, forKey: .repositoryOwner)
        repositoryName = try c.decodeIfPresent(String.self, forKey: .repositoryName)
        prStatus = try c.decodeIfPresent(String.self, forKey: .prStatus)
        prNumber = try c.decodeIfPresent(Int.self, forKey: .prNumber)
        diffSummaryTotalFiles = try c.decodeIfPresent(Int.self, forKey: .diffSummaryTotalFiles)
        taskStatsTotal = try c.decodeIfPresent(Int.self, forKey: .taskStatsTotal)
        taskStatsCompleted = try c.decodeIfPresent(Int.self, forKey: .taskStatsCompleted)
        taskStatsInProgress = try c.decodeIfPresent(Int.self, forKey: .taskStatsInProgress)
        agentSummaryCount = try c.decodeIfPresent(Int.self, forKey: .agentSummaryCount)
        agentSummaryAgents = try c.decodeIfPresent([WorkspaceAgentInfo].self, forKey: .agentSummaryAgents)
        pullRequests = try c.decodeIfPresent([WorkspacePullRequest].self, forKey: .pullRequests)
        activePullRequest = try c.decodeIfPresent(WorkspacePullRequest.self, forKey: .activePullRequest)
    }
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

