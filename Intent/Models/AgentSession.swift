import Foundation

struct AgentSession: Identifiable, Equatable {
    private struct AttentionRequestSurface {
        let kind: String
        let reason: String?
        let timestamp: String?

        init?(_ values: [String: Any]) {
            guard let kind = values["attentionRequestKind"] as? String else { return nil }
            self.kind = kind
            reason = values["attentionRequestReason"] as? String
            timestamp = values["attentionRequestTimestamp"] as? String
        }
    }

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
    let lastMessageRole: String?
    let digest: String?
    let specialist: String?
    let createdByAgentId: String?
    let attentionRequestKind: String?
    let attentionRequestReason: String?
    let attentionRequestTimestamp: String?
    var pendingQuestionsMessageId: String?
    var dismissedQuestionsMessageId: String?
    var notificationsMuted = false
    var parentAgentId: String?
    var retiredAt: String?
    var goal: String?

    private static let activeStatuses: Set<String> = [
        "active",
        "pending",
        "processing",
        "streaming",
        "busy",
        "responding",
        "waiting"
    ]

    var isActive: Bool {
        isStreaming || isProcessing || isResponding || Self.activeStatuses.contains(status.lowercased())
    }

    var displayMessage: String? {
        if lastMessageRole == "user", let userLine = Self.firstLine(lastUserMessage) {
            return userLine
        }
        guard let raw = digest ?? lastAgentResponse else { return nil }
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
        cleaned = cleaned.replacingOccurrences(
            of: "<agent_digest>[\\s\\S]*?</agent_digest>",
            with: "",
            options: .regularExpression
        )
        cleaned = SuggestedPrompts.stripBlocks(from: cleaned)
        cleaned = cleaned.replacingOccurrences(
            of: "<!--(?![ \\t]*suggested-prompts[ \\t]*(\\r?\\n|$))[\\s\\S]*?-->",
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

    var hasPendingQuestions: Bool {
        guard let pending = pendingQuestionsMessageId, !pending.isEmpty else { return false }
        return pending != dismissedQuestionsMessageId
    }

    var pendingAttentionRequest: PendingAttentionRequest? {
        guard let kind = attentionRequestKind else { return nil }
        return PendingAttentionRequest(
            kind: AgentAttentionKind(wire: kind),
            reason: Self.oneLiner(attentionRequestReason),
            raisedAt: ISO8601DateFormatter.lenientDate(from: attentionRequestTimestamp)
        )
    }

    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    private static func oneLiner(_ text: String?) -> String? {
        guard let text else { return nil }
        let collapsed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }

    var bestTimestamp: String? {
        lastActivity ?? updatedAt ?? createdAt
    }

    func applyingPreview(lastAgentResponse: String?, digest: String?) -> Self {
        Self(
            id: id,
            name: name,
            status: status,
            isBackground: isBackground,
            isStreaming: isStreaming,
            isProcessing: isProcessing,
            isResponding: isResponding,
            isWaitingForOtherAgents: isWaitingForOtherAgents,
            waitingForAgentIds: waitingForAgentIds,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastActivity: lastActivity,
            lastAgentResponse: lastAgentResponse ?? self.lastAgentResponse,
            lastUserMessage: lastUserMessage,
            lastMessageRole: lastAgentResponse != nil ? "assistant" : self.lastMessageRole,
            digest: digest ?? self.digest,
            specialist: specialist,
            createdByAgentId: createdByAgentId,
            attentionRequestKind: attentionRequestKind,
            attentionRequestReason: attentionRequestReason,
            attentionRequestTimestamp: attentionRequestTimestamp,
            pendingQuestionsMessageId: pendingQuestionsMessageId,
            dismissedQuestionsMessageId: dismissedQuestionsMessageId,
            notificationsMuted: notificationsMuted,
            parentAgentId: parentAgentId,
            retiredAt: retiredAt,
            goal: goal
        )
    }

    static func displayName(for name: String) -> String {
        name.caseInsensitiveCompare("Chief of Staff") == .orderedSame ? "Assistant" : name
    }

    static func parseAgent(_ dict: [String: Any]) -> Self? {
        guard let id = dict["id"] as? String,
              let name = dict["name"] as? String else { return nil }
        let metadata = dict["metadata"] as? [String: Any]
        let attentionSurface = attentionRequestSurface(dict)
        return Self(
            id: id,
            name: displayName(for: name),
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
            lastMessageRole: dict["lastMessageRole"] as? String,
            digest: dict["digest"] as? String,
            specialist: metadata?["specialist"] as? String,
            createdByAgentId: metadata?["createdByAgentId"] as? String,
            attentionRequestKind: attentionSurface?.kind,
            attentionRequestReason: attentionSurface?.reason,
            attentionRequestTimestamp: attentionSurface?.timestamp,
            pendingQuestionsMessageId: metadata?["pendingQuestionsMessageId"] as? String,
            dismissedQuestionsMessageId: metadata?["dismissedQuestionsMessageId"] as? String,
            notificationsMuted: dict["notificationsMuted"] as? Bool
                ?? metadata?["notificationsMuted"] as? Bool
                ?? false,
            parentAgentId: dict["parentAgentId"] as? String,
            retiredAt: dict["retiredAt"] as? String,
            goal: ConversationGoal.parse(dict["goal"])
        )
    }

    private static func attentionRequestSurface(_ dict: [String: Any]) -> AttentionRequestSurface? {
        if let surface = AttentionRequestSurface(dict) { return surface }
        if let metadata = dict["metadata"] as? [String: Any],
           let surface = AttentionRequestSurface(metadata) {
            return surface
        }
        return nil
    }
}

struct PendingAttentionRequest: Equatable {
    let kind: AgentAttentionKind
    let reason: String?
    let raisedAt: Date?

    init(kind: AgentAttentionKind, reason: String?, raisedAt: Date? = nil) {
        self.kind = kind
        self.reason = reason
        self.raisedAt = raisedAt
    }
}

enum AgentAttentionKind: Equatable {
    case blocker
    case discussion

    init(wire: String) {
        self = wire == "blocker" ? .blocker : .discussion
    }

    var label: String {
        switch self {
        case .discussion: return "Discussion requested"
        case .blocker: return "Blocker reported"
        }
    }

    var iconName: String {
        switch self {
        case .discussion: return "Message"
        case .blocker: return "AttentionCircleFill"
        }
    }
}

enum AgentAvatarState: Equatable {
    case attentionBlocker
    case attentionDiscussion
    case completed
    case failed
    case idle
    case question
    case running
    case waiting

    static func state(for session: AgentSession) -> Self {
        let status = session.status.lowercased()
        if status == "completed", !Self.isRunning(session) {
            return .completed
        }
        if session.isErrored {
            return .failed
        }
        if session.hasPendingQuestions {
            return .question
        }
        if !isTurnLive(session), let request = session.pendingAttentionRequest {
            switch request.kind {
            case .blocker: return .attentionBlocker
            case .discussion: return .attentionDiscussion
            }
        }
        if isBlockedWaiting(session) {
            return .waiting
        }
        if isRunning(session) {
            return .running
        }
        return .idle
    }

    var needsUser: Bool {
        switch self {
        case .question, .attentionDiscussion, .attentionBlocker: return true
        case .idle, .running, .waiting, .failed, .completed: return false
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .waiting: return "Waiting"
        case .failed: return "Failed"
        case .completed: return "Completed"
        case .question: return "Question pending"
        case .attentionDiscussion: return AgentAttentionKind.discussion.label
        case .attentionBlocker: return AgentAttentionKind.blocker.label
        }
    }

    private static let terminalStatuses: Set<String> = [
        "completed",
        "error",
        "failed",
        "deleted"
    ]

    private static func isTerminal(_ session: AgentSession) -> Bool {
        terminalStatuses.contains(session.status.lowercased())
    }

    private static func hasLiveTurnEvidence(_ session: AgentSession) -> Bool {
        session.isStreaming || session.isProcessing || session.isResponding
    }

    private static func isTurnLive(_ session: AgentSession) -> Bool {
        !isTerminal(session) && hasLiveTurnEvidence(session)
    }

    private static func isBlockedWaiting(_ session: AgentSession) -> Bool {
        if isTerminal(session) || hasLiveTurnEvidence(session) { return false }
        return session.isWaitingForOtherAgents || session.status.lowercased() == "waiting"
    }

    private static func isRunning(_ session: AgentSession) -> Bool {
        if isBlockedWaiting(session) { return false }
        if hasLiveTurnEvidence(session) { return true }
        return !isTerminal(session) && session.isActive
    }
}
