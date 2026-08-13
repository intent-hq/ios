import Foundation

/// Attribution for agent-to-agent messages. The daemon tags user-role rows
/// sent by another agent with
/// `{ type: "agent_message", fromAgentId, fromAgentName? }` — including on
/// queued entries' `messageMetadata`. Extraction is metadata-first with
/// graceful fallback: absent or malformed metadata (wrong type,
/// missing/empty `fromAgentId`) returns nil so the entry renders exactly as
/// before (FE parity: `agent-message-attribution.ts`).
struct AgentMessageAttribution: Equatable {
    /// Sender agent id.
    let fromAgentId: String
    /// Display name for the sender ("Agent" fallback, truncated to ~20 chars).
    let displayName: String

    private static let maxNameLength = 20
    private static let fallbackName = "Agent"

    /// Extracts agent-message attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type == "agent_message"` with a non-empty
    /// `fromAgentId`.
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

extension QueuedMessage {
    /// Agent-to-agent sender attribution for a queued entry
    /// (`messageMetadata.type == "agent_message"`).
    var agentMessageAttribution: AgentMessageAttribution? {
        AgentMessageAttribution.from(messageMetadata)
    }
}
