import SwiftUI

/// Generic muted banner for system-role rows that are not classified
/// attention notices — e.g. `meta.kind = "interruption"` restart notices or
/// unknown future kinds — so they still render instead of disappearing.
/// FE parity: InterruptionNotice.svelte (ChatMessage.svelte system-branch
/// fallback).
struct SystemNoticeBannerView: View {
    /// The system message text; empty falls back to the default restart notice.
    let message: String

    static let defaultMessage = "This conversation was interrupted because intentd restarted."

    private var displayText: String {
        message.isEmpty ? Self.defaultMessage : message
    }

    var body: some View {
        HStack(alignment: .top, spacing: Constants.Conversation.NoticeCard.contentSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .padding(.top, Constants.Conversation.NoticeCard.iconTopPadding)

            Text(displayText)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
        .padding(.horizontal, Constants.Conversation.NoticeCard.horizontalPadding)
        .padding(.vertical, Constants.Conversation.NoticeCard.verticalPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(Constants.Conversation.NoticeCard.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Constants.Conversation.NoticeCard.cornerRadius)
                .strokeBorder(
                    Color.orange.opacity(Constants.Conversation.NoticeCard.borderOpacity),
                    lineWidth: Constants.Conversation.NoticeCard.borderWidth)
        )
    }
}
