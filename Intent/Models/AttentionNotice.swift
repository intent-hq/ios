import Foundation

/// The kind of a daemon-persisted attention-request transcript notice
/// (PROTOCOL §5.5 agent attention requests). Raised by
/// `ws.agent.requestDiscussion(reason)` / `ws.agent.reportBlocker(reason)`,
/// or appended by intentd when a turn ends in a terminal failure
/// (`turn-failure`).
enum AttentionNoticeKind: String {
    case blockerReport = "blocker-report"
    case discussionRequest = "discussion-request"
    case turnFailure = "turn-failure"
}

/// A classified attention-request notice extracted from a system-role
/// transcript message whose first content block carries
/// `meta.kind = "discussion-request"`, `"blocker-report"`, or
/// `"turn-failure"`.
struct AttentionNotice: Equatable {
    let kind: AttentionNoticeKind
    /// The reason text carried by the notice message.
    let reason: String
}

extension ConversationMessage {
    /// Returns the attention notice when this message is a daemon-persisted
    /// attention-request row (system role, discriminated on the first content
    /// block's `meta.kind`), or nil for every other message — unknown kinds
    /// fall back to the generic system banner (FE parity: attention-notice.ts).
    var attentionNotice: AttentionNotice? {
        guard role == .system,
              let kindValue = contentBlocks.first?.resolvedMetadata["kind"]?.value as? String,
              let kind = AttentionNoticeKind(rawValue: kindValue) else {
            return nil
        }
        return AttentionNotice(kind: kind, reason: joinedTextContent)
    }

    /// All text-block content joined and trimmed (FE parity:
    /// `extractAllContent`). Used for notice reasons and the generic
    /// system-row fallback banner.
    var joinedTextContent: String {
        contentBlocks
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
