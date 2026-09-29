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
    /// Untruncated sender name ("Agent" fallback) — used where the full
    /// name matters, e.g. titling the pushed sender conversation (the
    /// `HookWakeAttribution.rawName` precedent).
    let rawName: String
    /// Display name for the sender ("Agent" fallback, truncated to ~20 chars).
    let displayName: String

    private static let maxNameLength = 20
    private static let fallbackName = "Agent"

    /// Extracts sender attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type == "agent_message"` and
    /// `metadata.fromAgentId` is a non-empty string.
    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        guard metadata["type"]?.stringValue == "agent_message" else { return nil }
        let fromAgentId = (metadata["fromAgentId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromAgentId.isEmpty else { return nil }

        let trimmedName = (metadata["fromAgentName"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmedName.isEmpty ? fallbackName : AgentSession.displayName(for: trimmedName)
        let displayName = rawName.count > maxNameLength
            ? String(rawName.prefix(maxNameLength - 1)) + "…"
            : rawName
        return Self(
            fromAgentId: fromAgentId,
            rawName: rawName,
            displayName: displayName
        )
    }
}

extension ConversationMessage {
    /// Agent-to-agent sender attribution for this row: check the row's
    /// `metadata` first, then the persisted text blocks' `messageMetadata`,
    /// so rows missing one surface still render the header. The FE checks
    /// only the row metadata for agent messages — the block fallback follows
    /// this repo's `hookWakeAttribution` precedent as a harmless superset.
    var agentMessageAttribution: AgentMessageAttribution? {
        if let attribution = AgentMessageAttribution.from(metadata) { return attribution }
        for block in contentBlocks where block.type == .text {
            if let attribution = AgentMessageAttribution.from(block.messageMetadata) {
                return attribution
            }
        }
        return nil
    }
}
