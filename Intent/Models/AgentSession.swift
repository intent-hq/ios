import Foundation

struct AgentSession: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let isBackground: Bool
    let isStreaming: Bool
    let isProcessing: Bool
    let isResponding: Bool
    let isWaitingForOtherAgents: Bool
    let waitingForAgentIds: [String]
    let createdAt: String?
    let updatedAt: String?
    let lastActivity: String?
    let lastAgentResponse: String?
    let lastUserMessage: String?
    let digest: String?
    let specialist: String?
    let createdByAgentId: String?
    /// Pending attention request (PROTOCOL §5.5 agent attention requests).
    /// "discussion" | "blocker"; nil when no request is pending (older daemons
    /// never send these fields).
    let attentionRequestKind: String?
    let attentionRequestReason: String?
    let attentionRequestTimestamp: String?

    private static let activeStatuses: Set<String> = [
        "active", "pending", "processing",
        "streaming", "busy", "responding", "waiting"
    ]

    var isActive: Bool {
        isStreaming || isProcessing || isResponding || Self.activeStatuses.contains(status.lowercased())
    }

    var displayMessage: String? {
        guard let raw = digest ?? lastAgentResponse else { return nil }
        // Strip <group:Name> and </group> / </group:Name> tags
        var cleaned = raw.replacingOccurrences(
            of: "<group:[^>\\n<]+>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.replacingOccurrences(
            of: "</group(:[^>\\n<]+)?>",
            with: "",
            options: .regularExpression
        )
        // Also strip <agent_digest> tags if present
        cleaned = cleaned.replacingOccurrences(
            of: "<agent_digest>[\\s\\S]*?</agent_digest>",
            with: "",
            options: .regularExpression
        )
        // Also strip <!-- suggested-prompts ... --> comments
        cleaned = cleaned.replacingOccurrences(
            of: "<!--[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    var isErrored: Bool {
        status.lowercased() == "error" || status.lowercased() == "failed"
    }

    var hasPendingAttentionRequest: Bool {
        attentionRequestKind != nil
    }

    /// Kind-flavored display treatment for the pending attention request, or
    /// nil when none is pending. The reason is collapsed to a one-liner
    /// (same treatment as the `digest` one-liner surfaces).
    var pendingAttentionRequest: PendingAttentionRequest? {
        guard let kind = attentionRequestKind else { return nil }
        return PendingAttentionRequest(
            kind: AgentAttentionKind(wire: kind),
            reason: Self.oneLiner(attentionRequestReason)
        )
    }

    /// Collapses runs of whitespace/newlines into single spaces; nil when empty.
    private static func oneLiner(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    var bestTimestamp: String? {
        updatedAt ?? lastActivity ?? createdAt
    }

    /// Returns a copy with the digest replaced
    func withDigest(_ newDigest: String) -> AgentSession {
        AgentSession(
            id: id, name: name, status: status, isBackground: isBackground,
            isStreaming: isStreaming, isProcessing: isProcessing, isResponding: isResponding,
            isWaitingForOtherAgents: isWaitingForOtherAgents, waitingForAgentIds: waitingForAgentIds,
            createdAt: createdAt, updatedAt: updatedAt, lastActivity: lastActivity,
            lastAgentResponse: lastAgentResponse, lastUserMessage: lastUserMessage,
            digest: newDigest, specialist: specialist, createdByAgentId: createdByAgentId,
            attentionRequestKind: attentionRequestKind,
            attentionRequestReason: attentionRequestReason,
            attentionRequestTimestamp: attentionRequestTimestamp
        )
    }

    static func parseAgent(_ dict: [String: Any]) -> AgentSession? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else { return nil }
        let metadata = dict["metadata"] as? [String: Any]
        let attentionSurface = attentionRequestSurface(dict)
        return AgentSession(
            id: id,
            name: name,
            status: dict["status"] as? String ?? "Idle",
            isBackground: metadata?["isBackground"] as? Bool ?? false,
            isStreaming: dict["isStreaming"] as? Bool ?? false,
            isProcessing: dict["isProcessing"] as? Bool ?? false,
            isResponding: dict["isResponding"] as? Bool ?? false,
            isWaitingForOtherAgents: dict["isWaitingForOtherAgents"] as? Bool ?? false,
            waitingForAgentIds: dict["waitingForAgentIds"] as? [String] ?? [],
            createdAt: dict["createdAt"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            lastActivity: dict["lastActivity"] as? String,
            lastAgentResponse: dict["lastAgentResponse"] as? String,
            lastUserMessage: dict["lastUserMessage"] as? String,
            digest: dict["digest"] as? String,
            specialist: metadata?["specialist"] as? String,
            createdByAgentId: metadata?["createdByAgentId"] as? String,
            attentionRequestKind: attentionSurface?["attentionRequestKind"] as? String,
            attentionRequestReason: attentionSurface?["attentionRequestReason"] as? String,
            attentionRequestTimestamp: attentionSurface?["attentionRequestTimestamp"] as? String
        )
    }

    /// Resolves the surface carrying the attention-request trio: top-level on
    /// agent.getSession, mirrored under metadata on AgentLite (agent.list /
    /// agent.get); absent on both when no request is pending (PROTOCOL §5.5).
    /// The whole trio is read from whichever surface carries the kind so a
    /// mixed payload cannot blend fields from the two surfaces.
    private static func attentionRequestSurface(_ dict: [String: Any]) -> [String: Any]? {
        if dict["attentionRequestKind"] is String { return dict }
        if let metadata = dict["metadata"] as? [String: Any],
           metadata["attentionRequestKind"] is String {
            return metadata
        }
        return nil
    }

    /// Extracts the pending attention request straight from a raw agent dict,
    /// without requiring the full session parse (which needs id/name), so
    /// attention state can still raise/clear on a partial payload.
    static func parsePendingAttentionRequest(_ dict: [String: Any]) -> PendingAttentionRequest? {
        guard let surface = attentionRequestSurface(dict),
              let kind = surface["attentionRequestKind"] as? String else { return nil }
        return PendingAttentionRequest(
            kind: AgentAttentionKind(wire: kind),
            reason: oneLiner(surface["attentionRequestReason"] as? String)
        )
    }
}

/// A pending attention request ready for display (PROTOCOL §5.5).
struct PendingAttentionRequest: Equatable {
    let kind: AgentAttentionKind
    /// Reason collapsed to a single line; nil when absent or empty.
    let reason: String?
}

/// Kind vocabulary for agent attention requests: "discussion" | "blocker"
/// (PROTOCOL §5.5). Unknown wire kinds fall back to the discussion treatment
/// so newer daemons still surface an indicator.
enum AgentAttentionKind: Equatable {
    case discussion
    case blocker

    init(wire: String) {
        self = wire == "blocker" ? .blocker : .discussion
    }

    var label: String {
        switch self {
        case .discussion: return "Discussion requested"
        case .blocker: return "Blocker reported"
        }
    }

    var systemImage: String {
        switch self {
        case .discussion: return "bubble.left.and.bubble.right.fill"
        case .blocker: return "exclamationmark.octagon.fill"
        }
    }
}

