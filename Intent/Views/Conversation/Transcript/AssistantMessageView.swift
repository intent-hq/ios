import SwiftUI

struct AssistantMessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    private var blocks: [ContentBlock] { message.contentBlocks ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
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
        .padding(.vertical, 4)
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

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .accessibilityHidden(true)
            Text(message.error ?? "An error occurred")
                .font(.callout)
                .foregroundStyle(Theme.destructive(for: colorScheme))
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive(for: colorScheme).opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
