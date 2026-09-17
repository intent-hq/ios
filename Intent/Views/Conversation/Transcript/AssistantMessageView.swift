import SwiftUI

struct AssistantMessageView: View {
    private enum Layout {
        static let contentSpacing: CGFloat = 8
        static let verticalPadding: CGFloat = 4
    }

    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    /// Derived once per message value in `init` rather than on every `body`
    /// evaluation: the raw blocks, the prompt-stripped blocks grouped into
    /// render blocks, and the copy-menu text.
    private let blocks: [ContentBlock]
    private let renderBlocks: [RenderBlock]
    private let copyText: String

    init(
        message: ConversationMessage,
        workspaceId: String,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?,
        hydratingBlockIds: Set<String>,
        onHydrateBlock: ((_ blockId: String) -> Void)?
    ) {
        self.message = message
        self.workspaceId = workspaceId
        self.onNavigateToNote = onNavigateToNote
        self.hydratingBlockIds = hydratingBlockIds
        self.onHydrateBlock = onHydrateBlock
        let blocks = message.contentBlocks
        self.blocks = blocks
        let strippedBlocks = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
        self.renderBlocks = MessageBlockPartitioning.groupContentBlocks(
            strippedBlocks,
            isStreaming: message.isStreaming
        )
        self.copyText = MessageBlockPartitioning.assistantCopyText(from: blocks)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
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
            text: copyText,
            userStyled: false,
            isStreaming: message.isStreaming
        ))
    }
}

struct ErrorMessageView: View {
    private enum Layout {
        static let spacing: CGFloat = 6
        static let padding: CGFloat = 10
        static let backgroundOpacity: Double = 0.1
        static let cornerRadius: CGFloat = 8
    }

    let message: ConversationMessage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: Layout.spacing) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.destructive(for: colorScheme))
                .accessibilityHidden(true)
            Text(message.error ?? "An error occurred")
                .font(.callout)
                .foregroundStyle(Theme.destructive(for: colorScheme))
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive(for: colorScheme).opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}
