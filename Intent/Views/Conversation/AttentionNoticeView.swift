import SwiftUI

/// Kind-flavored notice card for daemon-persisted attention-request rows
/// (PROTOCOL §5.5): amber for a discussion request, red for a blocker report.
/// Visual sibling of cloudlands-fe's DiscussionRequestNotice.svelte /
/// BlockerReportNotice.svelte.
struct AttentionNoticeView: View {
    let notice: AttentionNotice
    @Environment(\.colorScheme) var colorScheme

    private var tint: Color {
        switch notice.kind {
        case .discussionRequest: return .orange
        case .blockerReport: return .red
        }
    }

    private var iconName: String {
        switch notice.kind {
        case .discussionRequest: return "bubble.left.and.bubble.right.fill"
        case .blockerReport: return "exclamationmark.triangle.fill"
        }
    }

    private var title: String {
        switch notice.kind {
        case .discussionRequest: return "Discussion requested"
        case .blockerReport: return "Blocker reported"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.subheadline)
                .foregroundStyle(tint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint)

                if !notice.reason.isEmpty {
                    Text(notice.reason)
                        .font(.subheadline)
                        .foregroundStyle(Theme.foreground(for: colorScheme).opacity(0.85))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(tint.opacity(0.3), lineWidth: 1)
        )
    }
}
