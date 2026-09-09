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
    /// Role of the conversation's newest user/assistant message:
    /// "user" | "assistant" (PROTOCOL §5.5). Nil when omitted (older daemons,
    /// or a transcript with neither role).
    let lastMessageRole: String?
    let digest: String?
    let specialist: String?
    let createdByAgentId: String?
    /// Pending attention request (PROTOCOL §5.5 agent attention requests).
    /// "discussion" | "blocker"; nil when no request is pending (older daemons
    /// never send these fields).
    let attentionRequestKind: String?
    let attentionRequestReason: String?
    let attentionRequestTimestamp: String?
    /// Pending structured-question markers (PROTOCOL §5.5 "Pending questions"),
    /// lifted under `metadata` on the AgentLite projection. A non-empty
    /// `pendingQuestionsMessageId` names the assistant message whose questions
    /// are unanswered; the empty string is the authoritative "nothing pending"
    /// clear, and both are omitted by legacy marker-less sessions. Defaulted so
    /// existing memberwise construction sites keep compiling.
    var pendingQuestionsMessageId: String? = nil
    var dismissedQuestionsMessageId: String? = nil

    private static let activeStatuses: Set<String> = [
        "active", "pending", "processing",
        "streaming", "busy", "responding", "waiting"
    ]

    var isActive: Bool {
        isStreaming || isProcessing || isResponding || Self.activeStatuses.contains(status.lowercased())
    }

    var displayMessage: String? {
        // Freshness wins (PROTOCOL §5.5): when the user's message is newest,
        // preview its first line instead of the stale agent response/digest.
        // The daemon flips lastMessageRole to "assistant" once mid-turn
        // streamed text is derivable, so no local turn-state logic is needed.
        if lastMessageRole == "user", let userLine = Self.firstLine(lastUserMessage) {
            return userLine
        }
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
        // Strip well-formed <!-- suggested-prompts --> blocks (never body text
        // that merely resembles one — see `SuggestedPrompts`)
        cleaned = SuggestedPrompts.stripBlocks(from: cleaned)
        // Also strip remaining HTML comments, excluding suggested-prompts
        // openers (which end their line) so a malformed one cannot capture body
        // text up to an embedded `-->` (e.g. a Mermaid edge)
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

    /// Questions are pending iff the pending marker is set (non-empty) and
    /// differs from the dismissal marker — the same derivation the daemon uses
    /// for the workspace `needs_attention` rollup (PROTOCOL §5.5).
    var hasPendingQuestions: Bool {
        guard let pending = pendingQuestionsMessageId, !pending.isEmpty else { return false }
        return pending != dismissedQuestionsMessageId
    }

    /// Kind-flavored display treatment for the pending attention request, or
    /// nil when none is pending. The reason is collapsed to a one-liner
    /// (same treatment as the `digest` one-liner surfaces).
    var pendingAttentionRequest: PendingAttentionRequest? {
        guard let kind = attentionRequestKind else { return nil }
        return PendingAttentionRequest(
            kind: AgentAttentionKind(wire: kind),
            reason: Self.oneLiner(attentionRequestReason),
            raisedAt: ISO8601DateFormatter.lenientDate(from: attentionRequestTimestamp)
        )
    }

    /// First non-empty line, trimmed; nil when the text is nil or blank.
    private static func firstLine(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
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
        lastActivity ?? updatedAt ?? createdAt
    }

    /// Returns a copy with mid-turn preview fields from an enriched
    /// `agent:stream:activity` payload applied. The daemon stamps
    /// `lastAgentResponse`/`digest` only when derived to non-empty, so nil
    /// inputs keep the existing values. Applying a live response also flips
    /// `lastMessageRole` to "assistant", mirroring the daemon's read-path
    /// overlay: the role flips with the response overlay only (a digest-only
    /// payload keeps the persisted role, same as the daemon), so the
    /// agent-side preview resumes once streamed response text is derivable.
    func applyingPreview(lastAgentResponse: String?, digest: String?) -> AgentSession {
        AgentSession(
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
            dismissedQuestionsMessageId: dismissedQuestionsMessageId
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
            lastMessageRole: dict["lastMessageRole"] as? String,
            digest: dict["digest"] as? String,
            specialist: metadata?["specialist"] as? String,
            createdByAgentId: metadata?["createdByAgentId"] as? String,
            attentionRequestKind: attentionSurface?["attentionRequestKind"] as? String,
            attentionRequestReason: attentionSurface?["attentionRequestReason"] as? String,
            attentionRequestTimestamp: attentionSurface?["attentionRequestTimestamp"] as? String,
            pendingQuestionsMessageId: metadata?["pendingQuestionsMessageId"] as? String,
            dismissedQuestionsMessageId: metadata?["dismissedQuestionsMessageId"] as? String
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
            reason: oneLiner(surface["attentionRequestReason"] as? String),
            raisedAt: ISO8601DateFormatter.lenientDate(from: surface["attentionRequestTimestamp"] as? String)
        )
    }
}

/// A pending attention request ready for display (PROTOCOL §5.5).
struct PendingAttentionRequest: Equatable {
    let kind: AgentAttentionKind
    /// Reason collapsed to a single line; nil when absent or empty.
    let reason: String?
    /// When the request was raised; nil when the daemon omitted the timestamp
    /// or it failed to parse.
    let raisedAt: Date?

    init(kind: AgentAttentionKind, reason: String?, raisedAt: Date? = nil) {
        self.kind = kind
        self.reason = reason
        self.raisedAt = raisedAt
    }
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

/// Avatar display state derived from an `AgentSession`, mirroring
/// cloudlands-fe `getAvatarState` (agent-avatar/avatar-state.ts) so both
/// clients color an agent the same way. Precedence, highest first:
/// completed (unless a turn is running) > failed > question >
/// attention (blocker/discussion, unless a turn is live) > waiting >
/// running > idle.
enum AgentAvatarState: Equatable {
    case idle
    case running
    case waiting
    case failed
    case completed
    case question
    case attentionDiscussion
    case attentionBlocker

    static func state(for session: AgentSession) -> AgentAvatarState {
        let status = session.status.lowercased()
        // A completed status yields to live work: a re-woken agent keeps its
        // stale "completed" status until the turn settles.
        if status == "completed" && !isRunning(session) {
            return .completed
        }
        if session.isErrored {
            return .failed
        }
        // An unanswered question needs a user response even while the agent
        // does unrelated work.
        if session.hasPendingQuestions {
            return .question
        }
        // A pending discussion/blocker is suppressed while a turn is live
        // (cloudlands `getAgentAttentionRequest`): a re-woken agent carrying a
        // stale request renders as running until the turn ends.
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

    /// The state needs the user to act (answer, discuss, or unblock).
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
        "completed", "error", "failed", "deleted"
    ]

    private static func isTerminal(_ session: AgentSession) -> Bool {
        terminalStatuses.contains(session.status.lowercased())
    }

    /// Strong evidence that a turn is doing work right now.
    private static func hasLiveTurnEvidence(_ session: AgentSession) -> Bool {
        session.isStreaming || session.isProcessing || session.isResponding
    }

    /// A turn is in flight right now: live-turn evidence on a non-terminal
    /// status (cloudlands `isAgentTurnLive`). Narrower than `isRunning` — a
    /// bare activity status without evidence does not count.
    private static func isTurnLive(_ session: AgentSession) -> Bool {
        !isTerminal(session) && hasLiveTurnEvidence(session)
    }

    /// Waiting requires an explicit wait and no live-turn evidence: a live
    /// turn or a stale "waiting" status with activity flags stays running.
    private static func isBlockedWaiting(_ session: AgentSession) -> Bool {
        if isTerminal(session) || hasLiveTurnEvidence(session) { return false }
        return session.isWaitingForOtherAgents || session.status.lowercased() == "waiting"
    }

    /// Live-turn evidence always counts as running (a stale terminal status is
    /// overtaken by a re-woken turn); a bare activity status counts only when
    /// the status is not terminal.
    private static func isRunning(_ session: AgentSession) -> Bool {
        if isBlockedWaiting(session) { return false }
        if hasLiveTurnEvidence(session) { return true }
        return !isTerminal(session) && session.isActive
    }
}

