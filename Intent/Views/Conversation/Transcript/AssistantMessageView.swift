import SwiftUI

struct AssistantMessageView: View {
    private typealias Layout = Constants.Conversation.AssistantMessage

    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var hydratingBlockIds: Set<String>
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    /// Derived once per message value in `init` rather than on every `body`
    /// evaluation: the prompt-stripped blocks grouped into render blocks,
    /// the tool_use → tool_result pairing, and the copy-menu text.
    private let renderBlocks: [RenderBlock]
    private let toolResults: [String: ContentBlock]
    private let copyText: String

    init(
        message: ConversationMessage,
        workspaceId: String,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?,
        hydratingBlockIds: Set<String>,
        onLayoutChange: (() -> Void)? = nil,
        onHydrateBlock: ((_ blockId: String) -> Void)?
    ) {
        self.message = message
        self.workspaceId = workspaceId
        self.onNavigateToNote = onNavigateToNote
        self.hydratingBlockIds = hydratingBlockIds
        self.onLayoutChange = onLayoutChange
        self.onHydrateBlock = onHydrateBlock
        let blocks = message.contentBlocks
        let strippedBlocks = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
        self.renderBlocks = MessageBlockPartitioning.groupContentBlocks(
            strippedBlocks,
            isStreaming: message.isStreaming
        )
        self.toolResults = MessageBlockPartitioning.pairToolResults(blocks)
        self.copyText = MessageBlockPartitioning.assistantCopyText(from: blocks)
    }

    /// True while `block` or its paired tool result is being hydrated.
    private func isHydrating(_ block: ContentBlock) -> Bool {
        hydratingBlockIds.contains(block.id)
            || (toolResults[block.id].map { hydratingBlockIds.contains($0.id) } ?? false)
    }

    /// The pairing and hydration set narrowed to one group's children, so the
    /// group's equatable gate only sees changes that concern its own rows.
    private func groupInputs(_ group: ResponseGroup) -> (toolResults: [String: ContentBlock], hydrating: Set<String>) {
        var scopedResults: [String: ContentBlock] = [:]
        var hydrating: Set<String> = []
        for child in group.children {
            if let result = toolResults[child.id] {
                scopedResults[child.id] = result
                if hydratingBlockIds.contains(result.id) { hydrating.insert(result.id) }
            }
            if hydratingBlockIds.contains(child.id) { hydrating.insert(child.id) }
        }
        return (scopedResults, hydrating)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            ForEach(Array(renderBlocks.enumerated()), id: \.element.id) { index, renderBlock in
                switch renderBlock {
                case .contentBlock(let block):
                    ContentBlockView(
                        block: block,
                        toolResult: toolResults[block.id],
                        workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        isHydrating: isHydrating(block),
                        onLayoutChange: onLayoutChange,
                        onHydrateBlock: onHydrateBlock
                    )
                case .group(let group):
                    let isLastGroup = !renderBlocks.suffix(from: index + 1).contains { candidate in
                        if case .group = candidate { return true }
                        return false
                    }
                    let inputs = groupInputs(group)
                    ResponseGroupView(
                        group: group,
                        isLast: isLastGroup,
                        workspaceId: workspaceId,
                        onNavigateToNote: onNavigateToNote,
                        toolResults: inputs.toolResults,
                        hydratingBlockIds: inputs.hydrating,
                        onLayoutChange: onLayoutChange,
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
    private typealias Layout = Constants.Conversation.ErrorMessage

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
