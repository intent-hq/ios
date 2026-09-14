import SwiftUI

struct AssistantMessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    private enum Layout {
        static let contentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 4
    }

    private var blocks: [ContentBlock] { message.contentBlocks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            let strippedBlocks = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
            let renderBlocks = MessageBlockPartitioning.groupContentBlocks(
                strippedBlocks,
                isStreaming: message.isStreaming == true
            )

            ForEach(Array(renderBlocks.enumerated()), id: \.element.id) { index, renderBlock in
                switch renderBlock {
                case .contentBlock(let block):
                    ContentBlockView(
                        block: block,
                        allBlocks: blocks,
                        workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        hydratingBlockIds: hydratingBlockIds,
                        onHydrateBlock: onHydrateBlock
                    )
                case .group(let group):
                    let isLastGroup = !renderBlocks.suffix(from: index + 1).contains { candidate in
                        if case .group = candidate { return true }
                        return false
                    }
                    ResponseGroupView(
                        group: group,
                        isLast: isLastGroup,
                        workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        hydratingBlockIds: hydratingBlockIds,
                        onHydrateBlock: onHydrateBlock
                    )
                }
            }
        }
        .padding(.vertical, Layout.verticalPadding)
        .modifier(MessageCopyContextMenu(
            text: MessageBlockPartitioning.assistantCopyText(from: blocks),
            userStyled: false,
            isStreaming: message.isStreaming == true
        ))
    }
}

struct ErrorMessageView: View {
    let message: ConversationMessage
    @Environment(\.colorScheme) private var colorScheme

    private enum Layout {
        static let contentSpacing: CGFloat = 6
        static let containerPadding: CGFloat = 10
        static let backgroundOpacity: Double = 0.1
        static let cornerRadius: CGFloat = 8
    }

    var body: some View {
        HStack(spacing: Layout.contentSpacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .accessibilityHidden(true)
            Text(message.error ?? "An error occurred")
                .font(.callout)
                .foregroundStyle(Theme.destructive(for: colorScheme))
        }
        .padding(Layout.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive(for: colorScheme).opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}
