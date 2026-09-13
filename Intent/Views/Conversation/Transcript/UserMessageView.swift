import SwiftUI

struct UserMessageView: View {
    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    @Binding var isAgentMessageExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(BackendSession.self) private var session

    /// Derived once per message value in `init` rather than on every `body`
    /// evaluation (the body also re-runs on the expansion toggle): the wake /
    /// agent attributions, the partitioned blocks, and the copy-menu text.
    private let hookWake: HookWakeAttribution?
    private let prWake: PrMonitorWakeAttribution?
    private let agentMessage: AgentMessageAttribution?
    private let partitioned: (text: [ContentBlock], images: [ContentBlock], files: [ContentBlock])
    private let agentMessagePreview: String
    private let copyText: String

    init(
        message: ConversationMessage,
        workspaceId: String,
        onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?,
        isAgentMessageExpanded: Binding<Bool>
    ) {
        self.message = message
        self.workspaceId = workspaceId
        self.onNavigateToAgent = onNavigateToAgent
        self._isAgentMessageExpanded = isAgentMessageExpanded
        let blocks = message.contentBlocks ?? []
        let hookWake = message.hookWakeAttribution
        let prWake = hookWake == nil ? message.prMonitorWakeAttribution : nil
        self.hookWake = hookWake
        self.prWake = prWake
        self.agentMessage = hookWake == nil && prWake == nil ? message.agentMessageAttribution : nil
        self.partitioned = MessageBlockPartitioning.partitionUserBlocks(blocks)
        self.agentMessagePreview = MessageBlockPartitioning.agentMessagePreview(from: blocks)
        self.copyText = MessageBlockPartitioning.userCopyText(
            from: blocks, hookWake: hookWake, prWake: prWake)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let hookWake {
                HookWakeAttributionView(attribution: hookWake)
            } else if let prWake {
                PrMonitorWakeAttributionView(attribution: prWake, workspaceRepo: workspaceRepo)
            } else if let agentMessage {
                AgentMessageAttributionView(
                    attribution: agentMessage,
                    preview: agentMessagePreview,
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
                ForEach(partitioned.text) { block in
                    if let text = block.resolvedText {
                        userTextBlock(text, hookWake: hookWake, prWake: prWake)
                    }
                }

                if !partitioned.images.isEmpty {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: ImageAttachmentThumbnail.side, maximum: ImageAttachmentThumbnail.side), spacing: 6)],
                        alignment: .leading,
                        spacing: 6
                    ) {
                        ForEach(partitioned.images) { block in
                            ImageAttachmentThumbnail(block: block, workspaceId: workspaceId)
                        }
                    }
                    .padding(.top, 4)
                }

                if !partitioned.files.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(partitioned.files) { block in
                            fileAttachmentChip(block)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.muted(for: colorScheme).opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(MessageCopyContextMenu(
            text: copyText,
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
                    HookWakeAttribution.displayText(text, attribution: hookWake))
            }
            if prWake != nil {
                return MessageBlockPartitioning.stripSupervisorTags(
                    PrMonitorWakeAttribution.displayText(text))
            }
            return MessageBlockPartitioning.stripSupervisorTags(text)
        }()
        if (hookWake == nil && prWake == nil) || !display.isEmpty {
            let rows = MessageView.userTextRows(display)
            if rows.contains(where: { if case .chips = $0 { return true } else { return false } }) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        switch row {
                        case .text(let run):
                            userText(run)
                        case .chips(let mentions):
                            ChipFlowLayout(spacing: 6) {
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
            .foregroundStyle(Theme.foreground(for: colorScheme).opacity(0.85))
            .textSelection(.enabled)
    }

    private func fileAttachmentChip(_ block: ContentBlock) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            Text(block.fileName ?? "Attachment")
                .font(.caption)
                .lineLimit(1)
            if let size = block.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.muted(for: colorScheme).opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var workspaceRepo: String? {
        guard let workspace = session.workspaceStore.workspaces.first(
                where: { $0.id == workspaceId }),
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