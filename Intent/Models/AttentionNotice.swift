import Foundation

enum AttentionNoticeKind: String {
    case blockerReport = "blocker-report"
    case discussionRequest = "discussion-request"
    case turnFailure = "turn-failure"
}

struct AttentionNotice: Equatable {
    let kind: AttentionNoticeKind
    let reason: String
}

extension ConversationMessage {
    var attentionNotice: AttentionNotice? {
        guard role == .system,
              let kindValue = contentBlocks.first?.resolvedMetadata["kind"]?.value as? String,
              let kind = AttentionNoticeKind(rawValue: kindValue) else {
            return nil
        }
        return AttentionNotice(kind: kind, reason: joinedTextContent)
    }

    var joinedTextContent: String {
        contentBlocks
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
