import SwiftUI

struct AssistantMessageView: View {
    private typealias Layout = Constants.Conversation.AssistantMessage

    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.conversationPresentation) private var presentation

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
    private let hasStrippedPrompts: Bool
    private let proposalWorkspaceIDs: Set<String>

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
        self.proposalWorkspaceIDs = Set(blocks.compactMap(ActionProposal.parse).filter { $0.method != nil }.flatMap(\.workspaceIDs))
        let strippedBlocks = SuggestedPrompts.parse(contentBlocks: blocks).contentBlocks
        self.hasStrippedPrompts = strippedBlocks != blocks
        self.renderBlocks = MessageBlockPartitioning.groupContentBlocks(
            workspaceId == Workspace.chiefWorkspaceId ? WorkspaceLinks.coalescingTextBlocks(strippedBlocks) : strippedBlocks,
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(renderBlocks.enumerated()), id: \.element.id) { index, renderBlock in
                Group {
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
                        let inputs = groupInputs(group)
                        ResponseGroupView(
                            group: group,
                            isLast: isLastGroup(at: index),
                            workspaceId: workspaceId,
                            onNavigateToNote: onNavigateToNote,
                            toolResults: inputs.toolResults,
                            hydratingBlockIds: inputs.hydrating,
                            onLayoutChange: onLayoutChange,
                            onHydrateBlock: onHydrateBlock
                        )
                    }
                }
                .padding(.top, blockSpacing(at: index))
            }
            // Rebuild cached markdown when a streamed prompt block closes and disappears.
            .id(hasStrippedPrompts)
        }
        .padding(.vertical, workspaceDesign ? 0 : Layout.verticalPadding)
        .frame(maxWidth: presentation == .iPad ? .infinity : nil, alignment: .leading)
        .environment(\.assistantMessageStreaming, message.isStreaming)
        .environment(\.proposalMessageId, message.id)
        .environment(\.proposalWorkspaceIDs, proposalWorkspaceIDs)
        .modifier(MessageCopyContextMenu(
            text: copyText,
            userStyled: false,
            isStreaming: message.isStreaming
        ))
    }

    private func blockSpacing(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if workspaceDesign, renderBlocks[index - 1].isToolActivity, renderBlocks[index].isToolActivity {
            return 0
        }
        return workspaceDesign ? Constants.Conversation.Design.Transcript.toolRowSpacing : Layout.contentSpacing
    }

    private func isLastGroup(at index: Int) -> Bool {
        !renderBlocks.suffix(from: index + 1).contains { candidate in
            if case .group = candidate { return true }
            return false
        }
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
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Theme.destructive(for: colorScheme))
        }
        .padding(Layout.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive(for: colorScheme).opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
    }
}
