import SwiftUI

struct UserMessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    @Binding var isAgentMessageExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(BackendSession.self) private var session

    private enum Layout {
        static let contentSpacing: CGFloat = 4
        static let attachmentGridSpacing: CGFloat = 6
        static let attachmentSectionTopPadding: CGFloat = 4
        static let fileAttachmentListSpacing: CGFloat = 4
        static let containerPadding: CGFloat = 12
        static let backgroundOpacity: Double = 0.4
        static let cornerRadius: CGFloat = 8
        static let textRowSpacing: CGFloat = 6
        static let mentionChipSpacing: CGFloat = 6
        static let textOpacity: Double = 0.85
        static let fileChipSpacing: CGFloat = 6
        static let fileChipHorizontalPadding: CGFloat = 8
        static let fileChipVerticalPadding: CGFloat = 5
        static let fileChipBackgroundOpacity: Double = 0.6
        static let fileChipCornerRadius: CGFloat = 8
    }

    private var blocks: [ContentBlock] { message.contentBlocks ?? [] }

    var body: some View {
        let hookWake = message.hookWakeAttribution
        let prWake = hookWake == nil ? message.prMonitorWakeAttribution : nil
        let agentMessage = hookWake == nil && prWake == nil ? message.agentMessageAttribution : nil

        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            if let hookWake {
                HookWakeAttributionView(attribution: hookWake)
            } else if let prWake {
                PrMonitorWakeAttributionView(attribution: prWake, workspaceRepo: workspaceRepo)
            } else if let agentMessage {
                AgentMessageAttributionView(
                    attribution: agentMessage,
                    preview: MessageBlockPartitioning.agentMessagePreview(from: blocks),
                    isExpanded: $isAgentMessageExpanded,
                    onOpenAgent: onNavigateToAgent.map { navigate in
                        { navigate(agentMessage.fromAgentId, workspaceId, agentMessage.rawName) }
                    }
                )
            } else {
                Text("You")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }

            if agentMessage == nil || isAgentMessageExpanded {
                let partitioned = MessageBlockPartitioning.partitionUserBlocks(blocks)

                ForEach(partitioned.text) { block in
                    if let text = block.resolvedText {
                        userTextBlock(text, hookWake: hookWake, prWake: prWake)
                    }
                }

                if !partitioned.images.isEmpty {
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(
                                    minimum: ImageAttachmentThumbnail.side,
                                    maximum: ImageAttachmentThumbnail.side
                                ),
                                spacing: Layout.attachmentGridSpacing
                            )
                        ],
                        alignment: .leading,
                        spacing: Layout.attachmentGridSpacing
                    ) {
                        ForEach(partitioned.images) { block in
                            ImageAttachmentThumbnail(block: block, workspaceId: workspaceId)
                        }
                    }
                    .padding(.top, Layout.attachmentSectionTopPadding)
                }

                if !partitioned.files.isEmpty {
                    VStack(alignment: .leading, spacing: Layout.fileAttachmentListSpacing) {
                        ForEach(partitioned.files) { block in
                            fileAttachmentChip(block)
                        }
                    }
                    .padding(.top, Layout.attachmentSectionTopPadding)
                }
            }
        }
        .padding(Layout.containerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme).opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.cornerRadius))
        .modifier(MessageCopyContextMenu(
            text: MessageBlockPartitioning.userCopyText(
                from: blocks,
                hookWake: hookWake,
                prWake: prWake
            ),
            userStyled: true,
            isStreaming: false
        ))
    }

    @ViewBuilder
    private func userTextBlock(
        _ text: String,
        hookWake: HookWakeAttribution?,
        prWake: PrMonitorWakeAttribution?
    ) -> some View {
        let display: String = {
            if let hookWake {
                return MessageBlockPartitioning.stripSupervisorTags(
                    HookWakeAttribution.displayText(text, attribution: hookWake)
                )
            }
            if prWake != nil {
                return MessageBlockPartitioning.stripSupervisorTags(
                    PrMonitorWakeAttribution.displayText(text)
                )
            }
            return MessageBlockPartitioning.stripSupervisorTags(text)
        }()
        if (hookWake == nil && prWake == nil) || !display.isEmpty {
            let rows = MessageView.userTextRows(display)
            if rows.contains(where: { row in
                if case .chips = row { return true }
                return false
            }) {
                VStack(alignment: .leading, spacing: Layout.textRowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .text(let run):
                            userText(run)
                        case .chips(let mentions):
                            ChipFlowLayout(spacing: Layout.mentionChipSpacing) {
                                ForEach(Array(mentions.enumerated()), id: \.offset) { _, mention in
                                    ContextMentionChipView(mention: mention)
                                }
                            }
                        }
                    }
                }
            } else {
                userText(display)
            }
        }
    }

    private func userText(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(Theme.foreground(for: colorScheme).opacity(Layout.textOpacity))
            .textSelection(.enabled)
    }

    private func fileAttachmentChip(_ block: ContentBlock) -> some View {
        HStack(spacing: Layout.fileChipSpacing) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text(block.fileName ?? "Attachment")
                .font(.caption)
                .lineLimit(1)
            if let size = block.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .padding(.horizontal, Layout.fileChipHorizontalPadding)
        .padding(.vertical, Layout.fileChipVerticalPadding)
        .background(Theme.muted(for: colorScheme).opacity(Layout.fileChipBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Layout.fileChipCornerRadius))
    }

    private var workspaceRepo: String? {
        guard let workspace = session.workspaceStore.workspaces.first(
                where: { $0.id == workspaceId }
        ),
              let owner = workspace.repositoryOwner,
              let name = workspace.repositoryName else { return nil }
        return "\(owner)/\(name)"
    }
}

extension MessageView {
    enum UserTextRow: Equatable {
        case text(String)
        case chips([ContextMention])
    }

    static func userTextRows(_ text: String) -> [UserTextRow] {
        var rows: [UserTextRow] = []
        for segment in ContextMention.segments(from: text) {
            switch segment {
            case .text(let run):
                let trimmed = run.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { rows.append(.text(trimmed)) }
            case .mention(let mention):
                if case .chips(let chips)? = rows.last {
                    rows[rows.count - 1] = .chips(chips + [mention])
                } else {
                    rows.append(.chips([mention]))
                }
            }
        }
        return rows
    }
}
