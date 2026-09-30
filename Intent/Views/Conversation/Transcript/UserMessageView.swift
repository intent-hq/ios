import CoreText
import SwiftUI

struct UserMessageView: View {
    private typealias Layout = Constants.Conversation.UserMessage
    private typealias Design = Constants.Conversation.Design

    let message: ConversationMessage
    let workspaceId: String
    var onNavigateToAgent: ((_ agentId: String, _ workspaceId: String, _ agentName: String) -> Void)?
    @Binding var isAgentMessageExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(BackendSession.self) private var session
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.legibilityWeight) private var legibilityWeight
    @ScaledMetric(relativeTo: .body) private var workspaceFontSize = Constants.Typography.bodyS.size

    /// Derived once per message value in `init` rather than on every `body`
    /// evaluation (the body also re-runs on the expansion toggle): the wake /
    /// agent attributions, the partitioned blocks, and the copy-menu text.
    private let hookWake: HookWakeAttribution?
    private let prWake: PrMonitorWakeAttribution?
    private let agentMessage: AgentMessageAttribution?
    private let partitioned: UserBlockPartition
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
        let blocks = message.contentBlocks
        let hookWake = message.hookWakeAttribution
        let prWake = hookWake == nil ? message.prMonitorWakeAttribution : nil
        self.hookWake = hookWake
        self.prWake = prWake
        self.agentMessage = hookWake == nil && prWake == nil ? message.agentMessageAttribution : nil
        self.partitioned = MessageBlockPartitioning.partitionUserBlocks(blocks)
        self.agentMessagePreview = MessageBlockPartitioning.agentMessagePreview(from: blocks)
        self.copyText = MessageBlockPartitioning.userCopyText(
            from: blocks,
            hookWake: hookWake,
            prWake: prWake
        )
    }

    var body: some View {
        if workspaceDesign {
            WorkspaceUserBubbleLayout(usesFullWidth: dynamicTypeSize.isAccessibilitySize, layoutDirection: layoutDirection) {
                bubble
            }
        } else {
            bubble
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: Layout.contentSpacing) {
            attributionHeader
            if agentMessage == nil || isAgentMessageExpanded {
                messageContents
            }
        }
        .padding(workspaceDesign ? Design.Transcript.bubblePadding : Layout.containerPadding)
        .frame(maxWidth: workspaceDesign ? nil : .infinity, alignment: .leading)
        .background(workspaceDesign
            ? Design.Palette.surface(for: colorScheme)
            : Theme.muted(for: colorScheme).opacity(Layout.backgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: workspaceDesign ? Design.cornerRadius : Layout.cornerRadius))
        .modifier(MessageCopyContextMenu(
            text: copyText,
            userStyled: true,
            isStreaming: false
        ))
    }

    @ViewBuilder
    private var attributionHeader: some View {
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
        } else if !workspaceDesign {
            Text("You")
                .interFont(Constants.Typography.subtextXXS.withFace(.semibold))
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
    }

    @ViewBuilder
    private var messageContents: some View {
        ForEach(partitioned.text) { block in
            if let text = block.resolvedText {
                userTextBlock(text, hookWake: hookWake, prWake: prWake)
            }
        }
        if !partitioned.images.isEmpty {
            imageAttachments(partitioned.images)
        }
        if !partitioned.files.isEmpty {
            fileAttachments(partitioned.files)
        }
    }

    private func imageAttachments(_ images: [ContentBlock]) -> some View {
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
            ForEach(images) { block in
                ImageAttachmentThumbnail(block: block, workspaceId: workspaceId)
            }
        }
        .padding(.top, Layout.attachmentSectionTopPadding)
    }

    private func fileAttachments(_ files: [ContentBlock]) -> some View {
        VStack(alignment: .leading, spacing: Layout.fileAttachmentListSpacing) {
            ForEach(files) { block in
                fileAttachmentChip(block)
            }
        }
        .padding(.top, Layout.attachmentSectionTopPadding)
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
                userText(display, trimsBounds: usesTrimmedMessageText)
            }
        }
    }

    /// Keep native bounds between attributed headers, chips, attachments and multiple blocks.
    /// A plain bubble measures its existing padding from the cap top to the final baseline.
    private var usesTrimmedMessageText: Bool {
        workspaceDesign && hookWake == nil && prWake == nil && agentMessage == nil
            && partitioned.text.count == 1 && partitioned.images.isEmpty && partitioned.files.isEmpty
    }

    private var workspaceTextCapHeight: CGFloat {
        let style = Constants.Typography.bodyS
        let face = legibilityWeight == .bold ? style.face.legibleFace : style.face
        let font = CTFontCreateWithName(face.rawValue as CFString, workspaceFontSize, nil)
        return CTFontGetCapHeight(font)
    }

    @ViewBuilder
    private func userText(_ text: String, trimsBounds: Bool = false) -> some View {
        if trimsBounds, !text.isEmpty {
            WorkspaceTextTrimLayout(capHeight: workspaceTextCapHeight) {
                userTextContent(text)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            userTextContent(text)
        }
    }

    private func userTextContent(_ text: String) -> some View {
        Text(text)
            .interFont(workspaceDesign ? Constants.Typography.bodyS : Constants.Typography.bodyXS)
            .tracking(workspaceDesign ? Design.Typography.bodyTracking : 0)
            .foregroundStyle(workspaceDesign
                ? Design.Palette.foreground(for: colorScheme)
                : Theme.foreground(for: colorScheme).opacity(Layout.textOpacity))
            .textSelection(.enabled)
    }

    private func fileAttachmentChip(_ block: ContentBlock) -> some View {
        HStack(spacing: Layout.fileChipSpacing) {
            Image(systemName: "doc.fill")
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .accessibilityHidden(true)
            Text(block.fileName ?? "Attachment")
                .interFont(Constants.Typography.subtextXXS)
                .lineLimit(1)
            if let size = block.size {
                Text(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))
                    .interFont(Constants.Typography.subtextXXS)
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
