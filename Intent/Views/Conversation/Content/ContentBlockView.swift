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
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.conversationComposerFocus) private var composerFocus
    var disclosure = TranscriptDisclosure()
    private var thinkingExpanded: Bool {
        get { disclosure.binding(for: .thinking(block.id), default: false).wrappedValue }
        nonmutating set { disclosure.binding(for: .thinking(block.id), default: false).wrappedValue = newValue }
    }
    @State private var lightboxPresented = false
    @State private var pdfLink: PDFLinkPreviewView.Link?
    @State private var textLink: TextLinkPreviewView.Link?
    @State private var htmlLink: HTMLLinkPreviewView.Link?
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
                    textView(cleaned)
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
            // Action proposals render inline; question resources remain wizard-only.
            if let proposal = ActionProposal.parse(block) {
                ProposalCardView(proposal: proposal)
            }
        }
    }

    @ViewBuilder
    private func textView(_ text: String) -> some View {
        Group {
            if workspaceId == Workspace.chiefWorkspaceId {
                WorkspaceLinkedTextView(text: text, workspaceId: workspaceId, onOpenURL: openTextURL)
            } else {
                MarkdownTextView(text: text, onOpenURL: openTextURL, workspaceId: workspaceId)
            }
        }
        .fullScreenCover(item: $pdfLink) { link in
            PDFLinkPreviewView(link: link)
                .coversConversationComposers()
        }
        .fullScreenCover(item: $textLink) { link in
            TextLinkPreviewView(link: link)
                .coversConversationComposers()
        }
        .fullScreenCover(item: $htmlLink) { link in
            HTMLLinkPreviewView(link: link)
                .coversConversationComposers()
        }
    }

    private func openTextURL(_ url: URL) -> OpenURLAction.Result {
        switch Self.textURLRoute(for: url, workspaceId: workspaceId) {
        case .pdf(let link):
            pdfLink = link
        case .text(let link):
            textLink = link
        case .html(let link):
            htmlLink = link
        case let .note(noteId, targetWorkspaceId):
            if let onNavigateToNote {
                onNavigateToNote(noteId, targetWorkspaceId, "Note")
            } else {
                coordinator.onSelectNote(noteId, workspaceId: targetWorkspaceId, noteTitle: "Note")
            }
        case .system:
            // Defer to the inherited handler, which opens tracked pull requests in the app.
            openURL(url)
        }
        return .handled
    }

    @ViewBuilder
    private var thinkingView: some View {
        if workspaceDesign {
            WorkspaceThinkingView(text: block.resolvedText ?? "", isExpanded: thinkingExpansion)
        } else {
            legacyThinkingView
        }
    }

    private var legacyThinkingView: some View {
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
                    composerFocus?.wrappedValue = false
                    lightboxPresented = true
                }
            } label: {
                InlineImageThumbnail(image: uiImage)
                    .opacity(isHydrating
                        ? Constants.Conversation.ContentBlock.hydratingImageOpacity
                        : Constants.Conversation.ContentBlock.loadedImageOpacity)
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
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
                    .coversConversationComposers()
            }
            .onChange(of: block.dataTruncation) { _, truncation in
                // Hydration merged the full block in (the truncation flag
                // cleared): open the lightbox the tap asked for.
                if !truncation.isTruncated, lightboxPendingHydration {
                    lightboxPendingHydration = false
                    composerFocus?.wrappedValue = false
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
            .buttonStyle(IntentContentButtonStyle())
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

extension ContentBlockBody {
    enum TextURLRoute: Equatable {
        case pdf(PDFLinkPreviewView.Link)
        case text(TextLinkPreviewView.Link)
        case html(HTMLLinkPreviewView.Link)
        case note(id: String, workspaceId: String)
        case system
    }

    /// Shared by ordinary transcript markdown and the chief workspace's linked text.
    static func textURLRoute(for url: URL, workspaceId: String) -> TextURLRoute {
        if let link = IntentFileLink.parse(url), WorkspacePDF.isPDF(path: link.path) {
            return .pdf(.init(workspaceId: link.workspaceId ?? workspaceId, path: link.path))
        }
        if let link = IntentFileLink.parse(url), ["html", "htm"].contains(URL(fileURLWithPath: link.path).pathExtension.lowercased()) {
            return .html(.init(workspaceId: link.workspaceId ?? workspaceId, path: link.path))
        }
        if let link = IntentFileLink.parse(url), !link.isImage, !WorkspaceVideo.isVideo(path: link.path) {
            return .text(.init(workspaceId: link.workspaceId ?? workspaceId, path: link.path))
        }
        if let link = NoteDetailView.parseIntentNoteLink(url) {
            return .note(id: link.id, workspaceId: link.workspaceId ?? workspaceId)
        }
        return .system
    }
}
