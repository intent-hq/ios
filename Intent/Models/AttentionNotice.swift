import Foundation

/// The kind of a daemon-persisted attention-request transcript notice
/// (PROTOCOL §5.5 agent attention requests). Raised by
/// `ws.agent.requestDiscussion(reason)` / `ws.agent.reportBlocker(reason)`.
enum AttentionNoticeKind: String {
    case discussionRequest = "discussion-request"
    case blockerReport = "blocker-report"
}

/// A classified attention-request notice extracted from a system-role
/// transcript message whose first content block carries
/// `meta.kind = "discussion-request"` or `"blocker-report"`.
struct AttentionNotice: Equatable {
    let kind: AttentionNoticeKind
    /// The reason text carried by the notice message.
    let reason: String
}

extension ConversationMessage {
    /// Returns the attention notice when this message is a daemon-persisted
    /// attention-request row (system role, discriminated on the first content
    /// block's `meta.kind`), or nil for every other message — unknown kinds
    /// keep the existing rendering (FE parity: attention-notice.ts).
    var attentionNotice: AttentionNotice? {
        guard role == .system,
              let kindValue = contentBlocks?.first?.resolvedMetadata?["kind"]?.value as? String,
              let kind = AttentionNoticeKind(rawValue: kindValue) else {
            return nil
        }
        let reason = (contentBlocks ?? [])
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return AttentionNotice(kind: kind, reason: reason)
    }
}
