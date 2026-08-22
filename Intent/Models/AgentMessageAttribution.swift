import Foundation

/// Attribution for agent-to-agent messages. The daemon tags user-role rows
/// that were sent by another agent with
/// `metadata: { type: "agent_message", fromAgentId, fromAgentName? }` — on
/// the row's `metadata` and on the persisted text block's `messageMetadata`.
/// Extraction is metadata-first with graceful fallback: absent or malformed
/// metadata (wrong type, missing/blank `fromAgentId`) returns nil so the
/// message renders exactly as before (FE parity:
/// `agent-message-attribution.ts`).
struct AgentMessageAttribution: Equatable {
    /// Sender agent id (never empty — extraction fails without it).
    let fromAgentId: String
    /// Display name for the sender ("Agent" fallback, truncated to ~20 chars).
    let displayName: String

    private static let maxNameLength = 20
    private static let fallbackName = "Agent"

    /// Extracts sender attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type == "agent_message"` and
    /// `metadata.fromAgentId` is a non-empty string.
    static func from(_ metadata: [String: AnyCodable]?) -> AgentMessageAttribution? {
        guard let metadata, metadata["type"]?.stringValue == "agent_message" else { return nil }
        let fromAgentId = (metadata["fromAgentId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromAgentId.isEmpty else { return nil }

        let rawName = (metadata["fromAgentName"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = rawName.isEmpty ? fallbackName : rawName
        let displayName = name.count > maxNameLength
            ? String(name.prefix(maxNameLength - 1)) + "…"
            : name
        return AgentMessageAttribution(fromAgentId: fromAgentId, displayName: displayName)
    }
}

extension ConversationMessage {
    /// Agent-to-agent sender attribution for this row: the daemon tags the
    /// row's `metadata` AND the persisted text block's `messageMetadata` —
    /// check both so older rows missing one surface still render the header
    /// (FE parity: ChatMessage.svelte).
    var agentMessageAttribution: AgentMessageAttribution? {
        if let attribution = AgentMessageAttribution.from(metadata) { return attribution }
        for block in contentBlocks ?? [] where block.type == .text {
            if let attribution = AgentMessageAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}
