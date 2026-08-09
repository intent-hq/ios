import SwiftUI

/// Centered inline divider chip for daemon-delivered dismissal notification
/// rows (metadata `{ type: "questions_dismissed", … }`,
/// `agent.dismissQuestions`). Visually distinct from user/assistant bubbles —
/// the row informs the model that the user dismissed its pending questions
/// without answering (FE parity: QuestionsDismissedNotice.svelte).
struct QuestionsDismissedNoticeView: View {
    let notice: QuestionsDismissedNotice
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            line
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.slash")
                    .font(.caption2)
                Text("Questions dismissed")
                    .font(.caption)
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .fixedSize()
            line
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            notice.fullText.isEmpty ? "Questions dismissed" : notice.fullText)
    }

    private var line: some View {
        Rectangle()
            .fill(Theme.border(for: colorScheme))
            .frame(height: 1)
            .frame(maxWidth: .infinity)
    }
}
