import SwiftUI

/// "Copy" context menu with upright previews throughout the interaction in
/// the transcript's inverted-scroll hierarchy.
struct MessageCopyContextMenu: ViewModifier {
    let text: String
    let userStyled: Bool
    let isStreaming: Bool
    @Environment(\.colorScheme) private var colorScheme

    static func shouldEnableCopyInteraction(text: String, isStreaming: Bool) -> Bool {
        !text.isEmpty && !isStreaming
    }

    func body(content: Content) -> some View {
        content.overlay {
            CopyContextMenuOverlay(
                text: text,
                isEnabled: Self.shouldEnableCopyInteraction(
                    text: text,
                    isStreaming: isStreaming
                ),
                preview: AnyView(preview)
            )
        }
    }

    private var preview: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.foreground(for: colorScheme).opacity(
                userStyled ? Constants.Conversation.UserMessage.textOpacity : 1
            ))
            .lineLimit(Constants.Conversation.Message.contextPreviewLineLimit)
            .padding(Constants.Conversation.CopyContextMenu.previewPadding)
            .frame(
                maxWidth: Constants.Conversation.Message.contextPreviewMaximumWidth,
                alignment: .leading
            )
            .background(
                userStyled
                    ? Theme.muted(for: colorScheme).opacity(Constants.Conversation.UserMessage.backgroundOpacity)
                    : .clear
            )
            .background(Theme.background(for: colorScheme))
    }
}
