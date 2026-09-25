import Foundation

struct PairedServer: Codable, Equatable {
    let hosts: [String]
    let port: Int
    let name: String
    let pairedAt: Date
    let certFingerprint: String?
    /// Tailcat tunnel address ("tc..." connection token) when the daemon
    /// reported one — via the pairing payload (`tc=`) or `system.status`
    /// (`tcAddress`). Optional: absent on records saved before the field
    /// existed and on daemons without a running tunnel.
    let tcAddress: String?

    init(
        hosts: [String],
        port: Int,
        name: String,
        pairedAt: Date,
        certFingerprint: String? = nil,
        tcAddress: String? = nil
    ) {
        self.hosts = hosts
        self.port = port
        self.name = name
        self.pairedAt = pairedAt
        self.certFingerprint = certFingerprint
        self.tcAddress = tcAddress
    }
}

/// A route observation may patch an existing live shared row, never recreate
/// one or replace its credentials. The baseline detects competing rotations.
struct PendingBackendRoutePublication: Codable, Equatable {
    var updatedAt: Double
    var hosts: [String]
    var tcAddress: String?
    /// Time of the actual tunnel observation, unchanged by host-only edits.
    /// Legacy pending intents fall back to their original updatedAt.
    var tcUpdatedAt: Double?
    var previousTcAddress: String?
}

/// A saved daemon connection: pairing info plus its API token and metadata.
struct StoredConnection: Codable, Identifiable, Equatable {
    let id: UUID
    var server: PairedServer
    var token: String
    /// Daemon hostname when known, else first host:port.
    var displayName: String
    var lastConnectedAt: Date?
    /// `updatedAt` (ms since epoch) of the last iCloud-synced registry record
    /// applied or successfully published — the last-writer-wins clock for
    /// `SyncedBackendConnectionMerge`. `nil` on connections that predate sync
    /// or were paired locally and never matched a registry record.
    var syncUpdatedAt: Double?
    /// Durable local edit awaiting shared publication. Kept in the same
    /// device-local Keychain blob as the credentials; retries never restamp it.
    var pendingSyncUpdatedAt: Double?
    /// Provenance for automatic route publication. Ordinary imports have none;
    /// only an explicit pairing newer than a remembered removal can resume it.
    var localPairingSyncClock: Double?
    var pendingRoutePublication: PendingBackendRoutePublication?

    init(
        id: UUID,
        server: PairedServer,
        token: String,
        displayName: String? = nil,
        lastConnectedAt: Date? = nil,
        syncUpdatedAt: Double? = nil
    ) {
        self.id = id
        self.server = server
        self.token = token
        self.displayName = displayName ?? Self.fallbackDisplayName(for: server)
        self.lastConnectedAt = lastConnectedAt
        self.syncUpdatedAt = syncUpdatedAt
    }

    init(
        server: PairedServer,
        token: String,
        displayName: String? = nil,
        lastConnectedAt: Date? = nil,
        syncUpdatedAt: Double? = nil
    ) {
        self.init(
            id: UUID(),
            server: server,
            token: token,
            displayName: displayName,
            lastConnectedAt: lastConnectedAt,
            syncUpdatedAt: syncUpdatedAt
        )
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

    init(
        number: Int,
        status: String,
        title: String? = nil,
        url: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil
    ) {
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
    /// Id of the daemon's virtual Chief of Staff workspace. It is never shown
    /// in the workspace list: `workspace.list` filters it server-side, but a
    /// `workspace.subscribe` delta from an older daemon can still carry it, so
    /// the client drops it at every ingress as well.
    static let chiefWorkspaceId = "__chief__"

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
    let createdAt: String?
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
    let agentSummaryAgents: [WorkspaceAgentInfo]
    let pullRequests: [WorkspacePullRequest]  // detected-PR pool (§5.1)
    let agentSummaryWasReported: Bool
    let pullRequestsWereReported: Bool
    let activePullRequest: WorkspacePullRequest?  // single active PR (§5.1); nil when absent
    let statusImageAssetId: String?

    private enum CodingKeys: String, CodingKey {
        case activePullRequest
        case activity
        case agentSummaryAgents
        case agentSummaryCount
        case attention
        case baseRef
        case branch
        case createdAt
        case diffSummaryTotalFiles
        case displayStatus
        case id
        case lastActivity
        case prNumber
        case prStatus
        case pullRequests
        case repositoryName
        case repositoryOwner
        case status
        case statusImageAssetId
        case taskStatsCompleted
        case taskStatsInProgress
        case taskStatsTotal
        case title
        case updatedAt
        case waiting
    }

    /// Explicit initializer so `attention` / `waiting` / `createdAt` /
    /// `pullRequests` / `activePullRequest` can default — existing call sites
    /// (and test fixtures) that predate the fields stay valid.
    init(
        id: String,
        title: String,
        branch: String?,
        baseRef: String?,
        status: String?,
        activity: String?,
        displayStatus: String?,
        attention: String? = nil,
        waiting: Bool = false,
        lastActivity: String? = nil,
        createdAt: String? = nil,
        updatedAt: String? = nil,
        repositoryOwner: String? = nil,
        repositoryName: String? = nil,
        prStatus: String? = nil,
        prNumber: Int? = nil,
        diffSummaryTotalFiles: Int? = nil,
        taskStatsTotal: Int? = nil,
        taskStatsCompleted: Int? = nil,
        taskStatsInProgress: Int? = nil,
        agentSummaryCount: Int? = nil,
        agentSummaryAgents: [WorkspaceAgentInfo] = [],
        pullRequests: [WorkspacePullRequest] = [],
        agentSummaryWasReported: Bool = false,
        pullRequestsWereReported: Bool = false,
        activePullRequest: WorkspacePullRequest? = nil,
        statusImageAssetId: String? = nil
    ) {
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
        self.createdAt = createdAt
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
        self.agentSummaryWasReported = agentSummaryWasReported || !agentSummaryAgents.isEmpty
        self.pullRequestsWereReported = pullRequestsWereReported || !pullRequests.isEmpty
        self.activePullRequest = activePullRequest
        self.statusImageAssetId = WorkspaceStatusImageLayout.normalizedAssetId(statusImageAssetId)
    }

    /// Custom decode so `waiting` honors the wire contract (PROTOCOL §5.1:
    /// omitted when false) — the synthesized decoder would throw keyNotFound
    /// on the common not-waiting shape if a JSONDecoder path is ever added.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        branch = try container.decodeIfPresent(String.self, forKey: .branch)
        baseRef = try container.decodeIfPresent(String.self, forKey: .baseRef)
        status = try container.decodeIfPresent(String.self, forKey: .status)
        activity = try container.decodeIfPresent(String.self, forKey: .activity)
        displayStatus = try container.decodeIfPresent(String.self, forKey: .displayStatus)
        attention = try container.decodeIfPresent(String.self, forKey: .attention)
        waiting = try container.decodeIfPresent(Bool.self, forKey: .waiting) ?? false
        lastActivity = try container.decodeIfPresent(String.self, forKey: .lastActivity)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
        repositoryOwner = try container.decodeIfPresent(String.self, forKey: .repositoryOwner)
        repositoryName = try container.decodeIfPresent(String.self, forKey: .repositoryName)
        prStatus = try container.decodeIfPresent(String.self, forKey: .prStatus)
        prNumber = try container.decodeIfPresent(Int.self, forKey: .prNumber)
        diffSummaryTotalFiles = try container.decodeIfPresent(Int.self, forKey: .diffSummaryTotalFiles)
        taskStatsTotal = try container.decodeIfPresent(Int.self, forKey: .taskStatsTotal)
        taskStatsCompleted = try container.decodeIfPresent(Int.self, forKey: .taskStatsCompleted)
        taskStatsInProgress = try container.decodeIfPresent(Int.self, forKey: .taskStatsInProgress)
        agentSummaryCount = try container.decodeIfPresent(Int.self, forKey: .agentSummaryCount)
        if let decodedAgents = try container.decodeIfPresent([WorkspaceAgentInfo].self, forKey: .agentSummaryAgents) {
            agentSummaryAgents = decodedAgents
            agentSummaryWasReported = true
        } else {
            agentSummaryAgents = []
            agentSummaryWasReported = false
        }
        if let decodedPullRequests = try container.decodeIfPresent([WorkspacePullRequest].self, forKey: .pullRequests) {
            pullRequests = decodedPullRequests
            pullRequestsWereReported = true
        } else {
            pullRequests = []
            pullRequestsWereReported = false
        }
        activePullRequest = try container.decodeIfPresent(WorkspacePullRequest.self, forKey: .activePullRequest)
        statusImageAssetId = WorkspaceStatusImageLayout.normalizedAssetId(
            try container.decodeIfPresent(String.self, forKey: .statusImageAssetId)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(title, forKey: .title)
        try container.encodeIfPresent(branch, forKey: .branch)
        try container.encodeIfPresent(baseRef, forKey: .baseRef)
        try container.encodeIfPresent(status, forKey: .status)
        try container.encodeIfPresent(activity, forKey: .activity)
        try container.encodeIfPresent(displayStatus, forKey: .displayStatus)
        try container.encodeIfPresent(attention, forKey: .attention)
        if waiting { try container.encode(true, forKey: .waiting) }
        try container.encodeIfPresent(lastActivity, forKey: .lastActivity)
        try container.encodeIfPresent(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(updatedAt, forKey: .updatedAt)
        try container.encodeIfPresent(repositoryOwner, forKey: .repositoryOwner)
        try container.encodeIfPresent(repositoryName, forKey: .repositoryName)
        try container.encodeIfPresent(prStatus, forKey: .prStatus)
        try container.encodeIfPresent(prNumber, forKey: .prNumber)
        try container.encodeIfPresent(diffSummaryTotalFiles, forKey: .diffSummaryTotalFiles)
        try container.encodeIfPresent(taskStatsTotal, forKey: .taskStatsTotal)
        try container.encodeIfPresent(taskStatsCompleted, forKey: .taskStatsCompleted)
        try container.encodeIfPresent(taskStatsInProgress, forKey: .taskStatsInProgress)
        try container.encodeIfPresent(agentSummaryCount, forKey: .agentSummaryCount)
        if agentSummaryWasReported { try container.encode(agentSummaryAgents, forKey: .agentSummaryAgents) }
        if pullRequestsWereReported { try container.encode(pullRequests, forKey: .pullRequests) }
        try container.encodeIfPresent(activePullRequest, forKey: .activePullRequest)
        try container.encodeIfPresent(statusImageAssetId, forKey: .statusImageAssetId)
    }
}

/// A model available for the agent.
struct ModelInfo: Identifiable, Equatable {
    let id: String       // model id (e.g. "sonnet4.5")
    let name: String     // display name (e.g. "sonnet4.5 (balanced)")
    let provider: String // provider id (e.g. "auggie")
    var isDefault: Bool = false // provider-reported default model (models.list)
}

enum ProviderAuthentication: Equatable, ExpressibleByBooleanLiteral {
    case signedIn
    case signedOut
    case unknown

    init(booleanLiteral value: Bool) { self = value ? .signedIn : .signedOut }
}

/// An agent provider from `host.providerAuthStatus` (PROTOCOL §5.14).
struct ProviderInfo: Identifiable, Equatable {
    let id: String
    /// Tri-state: true (signed in), false (signed out), nil (unknown — probe failed or not installed).
    let authenticated: ProviderAuthentication

    init(id: String, authenticated: ProviderAuthentication = .unknown) {
        self.id = id
        self.authenticated = authenticated
    }

    /// Providers with `authenticated == false` are not selectable;
    /// `nil` (unknown) stays selectable since probes can fail transiently.
    var isSelectable: Bool { authenticated != .signedOut }

    var displayName: String { Self.displayName(for: id) }

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
        !isEmpty && !contains { $0.isSelectable }
    }
}
