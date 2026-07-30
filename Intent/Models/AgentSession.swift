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
            // Top-level on agent.getSession; mirrored under metadata on AgentLite
            // (agent.list / agent.get). Absent on both when no request is pending.
            attentionRequestKind: dict["attentionRequestKind"] as? String
                ?? metadata?["attentionRequestKind"] as? String,
            attentionRequestReason: dict["attentionRequestReason"] as? String
                ?? metadata?["attentionRequestReason"] as? String,
            attentionRequestTimestamp: dict["attentionRequestTimestamp"] as? String
                ?? metadata?["attentionRequestTimestamp"] as? String
        )
    }
}

