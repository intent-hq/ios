import Foundation

struct AgentMessageAttribution: Equatable {
    enum Kind: Equatable {
        case agent
        case chief
    }

    let fromAgentId: String
    let rawName: String
    let displayName: String
    var headerName: String?
    var kind: Kind = .agent

    private static let maxNameLength = 20
    private static let fallbackName = "Agent"

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

    private static let senderHeaderPattern =
        "^\\[MESSAGE FROM AGENT (?:[^\\n]+ )?\\(agent-[0-9a-f-]+\\)\\](?:\\n\\n?|$)"

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
