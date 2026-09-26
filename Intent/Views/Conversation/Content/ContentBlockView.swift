import SwiftUI

/// One rendered block of an assistant message. A thin shell over
/// `ContentBlockBody`: the message hands every block fresh closures on each
/// evaluation, so the block body is gated by `.equatable()` and only
/// re-renders when its own block, paired tool result, workspace, or
/// hydration flag changed — not when a streaming delta lands on a sibling.
struct ContentBlockView: View {
    let block: ContentBlock
    /// The `tool_result` paired with a `tool_use` block, pre-paired once per
    /// message by `AssistantMessageView`; nil for every other block type.
    var toolResult: ContentBlock?
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    /// True while this block (or its paired result) has an
    /// agent.getMessageBlock hydration fetch in flight (slim projection,
    /// PROTOCOL §5.5).
    var isHydrating = false
    var onLayoutChange: (() -> Void)?
    /// Fetch the full body of a slim-truncated block by id; absent → no
    /// hydration (bounded previews stay).
    var onHydrateBlock: ((_ blockId: String) -> Void)?

    var body: some View {
        ContentBlockBody(
            block: block,
            toolResult: toolResult,
            workspaceId: workspaceId,
            onNavigateToNote: onNavigateToNote,
            isHydrating: isHydrating,
            onLayoutChange: onLayoutChange,
            onHydrateBlock: onHydrateBlock
        )
        .equatable()
    }

    /// Decode an image block's base64 payload bytes; nil when absent or
    /// not valid base64.
    static func decodeImageData(_ block: ContentBlock) -> Data? {
        block.data.flatMap { Data(base64Encoded: $0) }
    }

    /// Decode an image block's base64 payload; nil on any decode failure.
    static func decodeImage(_ block: ContentBlock) -> UIImage? {
        decodeImageData(block).flatMap { UIImage(data: $0) }
    }

    /// Also shared by MessageView's whole-message copy so the copied text
    /// matches the rendered text (suggested-prompts blocks, HTML comments,
    /// `<agent_digest>` and supervisor tags all removed).
    static func stripSuggestedPrompts(_ text: String) -> String {
        // Only well-formed suggested-prompts blocks are removed; body text
        // that merely looks like one is left intact (see `SuggestedPrompts`).
        var result = SuggestedPrompts.stripBlocks(from: text)

        // Strip all other HTML comments. Suggested-prompts openers (which end
        // their line) are excluded so a malformed one cannot lazily capture body
        // text up to an embedded `-->` (e.g. a Mermaid edge).
        result = result.replacingOccurrences(
            of: "<!--(?![ \\t]*suggested-prompts[ \\t]*(\\r?\\n|$))[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )

        // Strip agent_digest tags
        result = result.replacingOccurrences(
            of: "<agent_digest>[\\s\\S]*?</agent_digest>",
            with: "",
            options: .regularExpression
        )

        // Strip supervisor tags
        result = result.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The value-compared block body behind `ContentBlockView`.
struct ContentBlockBody: View, Equatable {
    let block: ContentBlock
    let toolResult: ContentBlock?
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    let isHydrating: Bool
    var onLayoutChange: (() -> Void)?
    var onHydrateBlock: ((_ blockId: String) -> Void)?
    @Environment(AppCoordinator.self) var coordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var thinkingExpanded = false
    @State private var lightboxPresented = false
    /// Set when a thumbnail tap started hydration: the lightbox then opens
    /// automatically once the full block merges in (dataTruncated clears).
    @State private var lightboxPendingHydration = false

    /// Manual `==`: closures are excluded on purpose — the message builds
    /// new ones per evaluation, and they only capture stable identifiers.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.block == rhs.block
            && lhs.toolResult == rhs.toolResult
            && lhs.workspaceId == rhs.workspaceId
            && lhs.isHydrating == rhs.isHydrating
    }

    init(
        block: ContentBlock,
        toolResult: ContentBlock?,
        workspaceId: String,
        onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil,
        isHydrating: Bool = false,
        onLayoutChange: (() -> Void)? = nil,
        onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    ) {
        self.block = block
        self.toolResult = toolResult
        self.workspaceId = workspaceId
        self.onNavigateToNote = onNavigateToNote
        self.isHydrating = isHydrating
        self.onLayoutChange = onLayoutChange
        self.onHydrateBlock = onHydrateBlock
    }

    var body: some View {
        switch block.type {
        case .text:
            if let text = block.resolvedText {
                let cleaned = ContentBlockView.stripSuggestedPrompts(text)
                if !cleaned.isEmpty {
                    MarkdownTextView(
                        text: cleaned,
                        onOpenURL: { url in
                            if let link = NoteDetailView.parseIntentNoteLink(url) {
                                let targetWorkspaceId = link.workspaceId ?? workspaceId
                                if let onNavigateToNote {
                                    onNavigateToNote(link.id, targetWorkspaceId, "Note")
                                } else {
                                    coordinator.onSelectNote(link.id, workspaceId: targetWorkspaceId, noteTitle: "Note")
                                }
                                return .handled
                            }
                            return .systemAction
                        },
                        workspaceId: workspaceId
                    )
                }
            }

        case .code:
            CodeBlockView(
                code: block.resolvedText ?? "",
                language: block.language
            )

        case .toolUse:
            ToolCallView(
                block: block,
                toolResult: toolResult,
                isHydrating: isHydrating,
                onLayoutChange: onLayoutChange,
                onHydrate: onHydrateBlock.map { hydrate in
                    {
                        // Hydrate whichever side of the row was truncated
                        // (input and output are separate persisted blocks).
                        if block.inputTruncation.isTruncated { hydrate(block.id) }
                        if let toolResult, toolResult.outputTruncation.isTruncated { hydrate(toolResult.id) }
                    }
                }
            )

        case .toolResult:
            // Rendered as part of ToolCallView via pairing; skip standalone
            EmptyView()

        case .thinking:
            thinkingView

        case .image:
            imageView

        case .file:
            fileView

        case .resource:
            // Standalone resource blocks (PROTOCOL §7.1) never render in the
            // transcript; question resources are wizard-only and stripped by
            // MIME regardless of payload validity (FE parity).
            EmptyView()
        }
    }

    @ViewBuilder
    private var thinkingView: some View {
        DisclosureGroup(isExpanded: thinkingExpansion) {
            Text(block.resolvedText ?? "")
                .interFont(Constants.Typography.bodyS)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, Constants.Conversation.ContentBlock.thinkingTopPadding)
        } label: {
            HStack(spacing: Constants.Conversation.ContentBlock.thinkingLabelSpacing) {
                Image(systemName: "brain")
                    .font(.caption)
                    .accessibilityHidden(true)
                Text("Thinking")
                    .interFont(Constants.Typography.subtextXXS.withFace(.medium))
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .tint(Theme.mutedForeground(for: colorScheme))
    }

    private var thinkingExpansion: Binding<Bool> {
        Binding(
            get: { thinkingExpanded },
            set: { expanded in
                onLayoutChange?()
                thinkingExpanded = expanded
            }
        )
    }

    /// A slim-truncated image asks for the original on tap (PROTOCOL §5.5);
    /// the lightbox opens once hydration swaps the full block in (the
    /// truncation flag then disappears from the merged block).
    private var imageNeedsHydration: Bool {
        block.dataTruncation.isTruncated && onHydrateBlock != nil
    }

    @ViewBuilder
    private var imageView: some View {
        if block.data == nil, !block.dataTruncation.isTruncated, let attachmentId = block.attachmentId {
            // Attachment-reference block (PROTOCOL §5.5): no inline bytes —
            // resolve the registry row and fetch via file.readChunk.
            AttachmentReferenceImageView(
                workspaceId: workspaceId,
                attachmentId: attachmentId,
                style: .inline
            )
        } else if let uiImage = ContentBlockView.decodeImage(block) {
            // Full image, or the write-time thumbnail served by the slim
            // projection (dataIsThumbnail) — tapping a thumbnail hydrates.
            let imageData = ContentBlockView.decodeImageData(block)
            Button {
                if imageNeedsHydration {
                    lightboxPendingHydration = true
                    onHydrateBlock?(block.id)
                } else {
                    lightboxPresented = true
                }
            } label: {
                SquareImageThumbnail(image: uiImage, side: SquareImageThumbnail.transcriptSide)
                    .opacity(isHydrating
                        ? Constants.Conversation.ContentBlock.hydratingImageOpacity
                        : Constants.Conversation.ContentBlock.loadedImageOpacity)
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(imageNeedsHydration ? "Load attached image" : "Attached image")
            .contextMenu {
                // A slim-truncated block only carries the low-res preview
                // thumbnail — Save/Copy here would export it as if it were
                // the full image (and the info rows would describe the
                // preview). Suppress the menu; tapping hydrates the full
                // block, whose lightbox ellipsis menu offers the actions.
                if !block.dataTruncation.isTruncated {
                    ImageActionMenuItems(image: uiImage, originalData: imageData)
                }
            }
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: uiImage, data: imageData)
            }
            .onChange(of: block.dataTruncation) { _, truncation in
                // Hydration merged the full block in (the truncation flag
                // cleared): open the lightbox the tap asked for.
                if !truncation.isTruncated, lightboxPendingHydration {
                    lightboxPendingHydration = false
                    lightboxPresented = true
                }
            }
            .onChange(of: isHydrating) { _, hydrating in
                // Fetch settled without clearing the flag (failure): drop the
                // pending open so a later unrelated merge can't surprise-open.
                if !hydrating, block.dataTruncation.isTruncated {
                    lightboxPendingHydration = false
                }
            }
        } else if block.dataTruncation.isTruncated {
            // Slim row with no persisted thumbnail (legacy rows, failed
            // generation): placeholder chip with the same on-demand fetch.
            Button {
                onHydrateBlock?(block.id)
            } label: {
                HStack(spacing: Constants.Conversation.ContentBlock.loadingLabelSpacing) {
                    if isHydrating {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading image…")
                            .interFont(Constants.Typography.subtextXXS)
                    } else {
                        Image(systemName: "photo")
                            .accessibilityHidden(true)
                        Text(imageNeedsHydration ? "Tap to load image" : "Image")
                            .interFont(Constants.Typography.subtextXXS)
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .copyContextMenuPassthrough()
            }
            .buttonStyle(.plain)
            .disabled(!imageNeedsHydration || isHydrating)
        } else {
            ImageDecodeFailureView()
        }
    }

    @ViewBuilder
    private var fileView: some View {
        HStack(spacing: Constants.Conversation.ContentBlock.fileLabelSpacing) {
            Image(systemName: "doc")
                .font(.caption)
                .accessibilityHidden(true)
            Text(block.fileName ?? "File")
                .font(.caption.monospaced())
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, Constants.Conversation.ContentBlock.fileHorizontalPadding)
        .padding(.vertical, Constants.Conversation.ContentBlock.fileVerticalPadding)
        .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.ContentBlock.fileBackgroundOpacity))
        .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ContentBlock.fileCornerRadius))
    }
}
