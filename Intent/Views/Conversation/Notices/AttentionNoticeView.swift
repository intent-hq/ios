import SwiftUI

/// Kind-flavored notice card for daemon-persisted attention-request rows
/// (PROTOCOL §5.5): amber for a discussion request, red for a blocker report
/// or a terminal turn failure. Visual sibling of cloudlands-fe's
/// DiscussionRequestNotice.svelte / BlockerReportNotice.svelte /
/// TurnFailureNotice.svelte.
struct AttentionNoticeView: View {
    let notice: AttentionNotice
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    private var tint: Color {
        switch notice.kind {
        case .discussionRequest: return .orange
        case .blockerReport: return .red
        case .turnFailure: return .red
        }
    }

    private var iconName: String {
        switch notice.kind {
        case .discussionRequest: return "bubble.left.and.bubble.right.fill"
        case .blockerReport: return "exclamationmark.triangle.fill"
        case .turnFailure: return "xmark.circle.fill"
        }
    }

    private var title: String {
        switch notice.kind {
        case .discussionRequest: return "Discussion requested"
        case .blockerReport: return "Blocker reported"
        case .turnFailure: return "Turn failed"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Conversation.NoticeCard.contentSpacing) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
                .padding(.top, Constants.Conversation.NoticeCard.iconTopPadding)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.foreground(for: colorScheme))

                if !notice.reason.isEmpty {
                    Text(notice.reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.foreground(for: colorScheme))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, Constants.Conversation.NoticeCard.horizontalPadding)
        .padding(.vertical, Constants.Conversation.NoticeCard.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(
            colorSchemeContrast == .increased
                ? Constants.Conversation.NoticeCard.backgroundOpacity * 1.75
                : Constants.Conversation.NoticeCard.backgroundOpacity
        ))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius)
                .strokeBorder(
                    tint.opacity(colorSchemeContrast == .increased
                        ? 1
                        : Constants.Conversation.NoticeCard.borderOpacity),
                    lineWidth: colorSchemeContrast == .increased
                        ? Constants.Conversation.NoticeCard.borderWidth * 2
                        : Constants.Conversation.NoticeCard.borderWidth
                )
        )
    }
}
