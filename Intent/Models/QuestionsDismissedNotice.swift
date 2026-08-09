import Foundation

/// A daemon-delivered dismissal notification row (`agent.dismissQuestions`,
/// PROTOCOL §5.5). When the user dismisses an agent's pending questions,
/// intentd delivers a system-origin message ("User dismissed your N questions
/// without answering…") tagged with metadata `{ type: "questions_dismissed",
/// source: "system", dismissedQuestionsMessageId }` — on the row's `metadata`
/// and on the persisted text block's `messageMetadata`. The transcript renders
/// the delivered row as a compact divider chip instead of a plain user bubble
/// (FE parity: `questions-dismissed-notice.ts` / QuestionsDismissedNotice.svelte).
struct QuestionsDismissedNotice: Equatable {
    /// Message id of the dismissed question set (empty when omitted).
    let dismissedQuestionsMessageId: String
    /// Full delivered message text, surfaced for accessibility/long-press.
    let fullText: String
}

extension ConversationMessage {
    /// Returns the dismissal-notice info when this message is a
    /// daemon-delivered questions-dismissed row, or nil for every other
    /// message. Discriminates on `type == "questions_dismissed"` from the
    /// row's `metadata` first, falling back to the text blocks'
    /// `messageMetadata`, and stays tolerant of the exact role the daemon
    /// persists (FE parity: `getQuestionsDismissedNotice`).
    var questionsDismissedNotice: QuestionsDismissedNotice? {
        if let notice = Self.dismissalInfo(from: metadata) {
            return notice.withText(fullText)
        }
        for block in contentBlocks ?? [] where block.type == .text {
            if let notice = Self.dismissalInfo(from: block.messageMetadata) {
                return notice.withText(fullText)
            }
        }
        return nil
    }

    private var fullText: String {
        (contentBlocks ?? [])
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dismissalInfo(
        from metadata: [String: AnyCodable]?
    ) -> QuestionsDismissedNotice? {
        guard let metadata,
              metadata["type"]?.value as? String == "questions_dismissed" else {
            return nil
        }
        let dismissedId = metadata["dismissedQuestionsMessageId"]?.value as? String ?? ""
        return QuestionsDismissedNotice(
            dismissedQuestionsMessageId: dismissedId, fullText: "")
    }
}

private extension QuestionsDismissedNotice {
    func withText(_ text: String) -> QuestionsDismissedNotice {
        QuestionsDismissedNotice(
            dismissedQuestionsMessageId: dismissedQuestionsMessageId, fullText: text)
    }
}
