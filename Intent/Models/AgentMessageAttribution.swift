import Foundation

/// Attribution for agent-to-agent messages. The daemon tags user-role rows
/// that were sent by another agent with
/// `metadata: { type: "agent_message", fromAgentId, fromAgentName? }`
/// (`chief_message` for the Assistant) — on
/// the row's `metadata` and on the persisted text block's `messageMetadata`.
/// Extraction is metadata-first with graceful fallback: absent or malformed
/// metadata (wrong type, missing/blank `fromAgentId`) returns nil so the
/// message renders exactly as before (FE parity:
/// `agent-message-attribution.ts`).
struct AgentMessageAttribution: Equatable {
    enum Kind: Equatable {
        case agent
        /// `chief_message`: sent by the Assistant from its own workspace, so
        /// the sender id cannot be opened in this workspace.
        case chief
    }

    /// Sender agent id (never empty — extraction fails without it).
    let fromAgentId: String
    /// Untruncated sender name ("Agent" fallback) — used where the full
    /// name matters, e.g. titling the pushed sender conversation (the
    /// `HookWakeAttribution.rawName` precedent).
    let rawName: String
    /// Display name for the sender ("Agent" fallback, truncated to ~20 chars).
    let displayName: String
    /// Verbatim `fromAgentName` (nil when absent), as the daemon used it in
    /// the literal `[MESSAGE FROM AGENT …]` sender header.
    var headerName: String?
    var kind: Kind = .agent

    private static let maxNameLength = 20
    private static let fallbackName = "Agent"

    /// Extracts sender attribution from an opaque metadata dictionary.
    /// Returns nil unless `metadata.type` is `agent_message` or
    /// `chief_message` and `metadata.fromAgentId` is a non-empty string.
    static func from(_ metadata: [String: AnyCodable]) -> Self? {
        let kind: Kind
        switch metadata["type"]?.stringValue {
        case "agent_message": kind = .agent
        case "chief_message": kind = .chief
        default: return nil
        }
        let fromAgentId = (metadata["fromAgentId"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fromAgentId.isEmpty else { return nil }

        let headerName = metadata["fromAgentName"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let trimmedName = (headerName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawName = trimmedName.isEmpty ? fallbackName : AgentSession.displayName(for: trimmedName)
        let displayName = rawName.count > maxNameLength
            ? String(rawName.prefix(maxNameLength - 1)) + "…"
            : rawName
        return Self(
            fromAgentId: fromAgentId,
            rawName: rawName,
            displayName: displayName,
            headerName: headerName,
            kind: kind
        )
    }

    /// The daemon's sender header shape when no attribution is available;
    /// the `(agent-…)` tail keeps a user-written lookalike line intact.
    private static let senderHeaderPattern =
        "^\\[MESSAGE FROM AGENT (?:[^\\n]+ )?\\(agent-[0-9a-f-]+\\)\\](?:\\n\\n?|$)"

    /// Display-only strip of the `[MESSAGE FROM AGENT {name} ({id})]` header
    /// plus its one blank separator line. The exact header rebuilt from the
    /// row's metadata wins; the pinned regex covers rows without it. Text that
    /// does not start with the daemon shape is returned unchanged
    /// (FE parity: `stripAgentMessageHeader`).
    static func stripSenderHeader(_ text: String, attribution: Self?) -> String {
        if let attribution {
            let literal = attribution.headerName.map { "[MESSAGE FROM AGENT \($0) (\(attribution.fromAgentId))]" }
                ?? "[MESSAGE FROM AGENT (\(attribution.fromAgentId))]"
            if let stripped = stripLiteralHeader(text, prefix: literal) { return stripped }
        }
        guard let range = text.range(of: senderHeaderPattern, options: .regularExpression) else { return text }
        return String(text[range.upperBound...])
    }

    private static func stripLiteralHeader(_ text: String, prefix: String) -> String? {
        guard text.hasPrefix(prefix) else { return nil }
        let rest = text.dropFirst(prefix.count)
        if rest.isEmpty { return "" }
        if rest.hasPrefix("\n\n") { return String(rest.dropFirst(2)) }
        if rest.hasPrefix("\n") { return String(rest.dropFirst()) }
        return nil
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
