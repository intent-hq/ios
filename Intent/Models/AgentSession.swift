import Foundation

struct AgentSession: Identifiable, Equatable {
    let id: String
    let name: String
    let status: String
    let isBackground: Bool
    let isStreaming: Bool
    let isProcessing: Bool
    let isResponding: Bool
    let createdAt: String?
    let updatedAt: String?
    let lastActivity: String?
    let lastAgentResponse: String?
    let lastUserMessage: String?
    let digest: String?
    let specialist: String?
    let createdByAgentId: String?

    private static let activeStatuses: Set<String> = [
        "active", "Active", "pending", "Processing",
        "streaming", "processing", "busy", "responding"
    ]

    var isActive: Bool {
        isStreaming || isProcessing || isResponding || Self.activeStatuses.contains(status)
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

    var bestTimestamp: String? {
        updatedAt ?? lastActivity ?? createdAt
    }

    /// Returns a copy with the digest replaced
    func withDigest(_ newDigest: String) -> AgentSession {
        AgentSession(
            id: id, name: name, status: status, isBackground: isBackground,
            isStreaming: isStreaming, isProcessing: isProcessing, isResponding: isResponding,
            createdAt: createdAt, updatedAt: updatedAt, lastActivity: lastActivity,
            lastAgentResponse: lastAgentResponse, lastUserMessage: lastUserMessage,
            digest: newDigest, specialist: specialist, createdByAgentId: createdByAgentId
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
            createdAt: dict["createdAt"] as? String,
            updatedAt: dict["updatedAt"] as? String,
            lastActivity: dict["lastActivity"] as? String,
            lastAgentResponse: dict["lastAgentResponse"] as? String,
            lastUserMessage: dict["lastUserMessage"] as? String,
            digest: dict["digest"] as? String,
            specialist: metadata?["specialist"] as? String,
            createdByAgentId: metadata?["createdByAgentId"] as? String
        )
    }
}

