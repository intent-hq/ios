import Foundation

struct QuestionsDismissedNotice: Equatable {
    let dismissedQuestionsMessageId: String
    let fullText: String
}

extension ConversationMessage {
    var questionsDismissedNotice: QuestionsDismissedNotice? {
        if let notice = Self.dismissalInfo(from: metadata) {
            return notice.withText(fullText)
        }
        for block in contentBlocks where block.type == .text {
            if let notice = Self.dismissalInfo(from: block.messageMetadata) {
                return notice.withText(fullText)
            }
        }
        return nil
    }

    private var fullText: String {
        contentBlocks
            .filter { $0.type == .text }
            .compactMap { $0.resolvedText }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func dismissalInfo(
        from metadata: [String: AnyCodable]
    ) -> QuestionsDismissedNotice? {
        guard metadata["type"]?.value as? String == "questions_dismissed" else {
            return nil
        }
        let dismissedId = metadata["dismissedQuestionsMessageId"]?.value as? String ?? ""
        return QuestionsDismissedNotice(
            dismissedQuestionsMessageId: dismissedId,
            fullText: ""
        )
    }
}

private extension QuestionsDismissedNotice {
    func withText(_ text: String) -> QuestionsDismissedNotice {
        QuestionsDismissedNotice(
            dismissedQuestionsMessageId: dismissedQuestionsMessageId,
            fullText: text
        )
    }
}
