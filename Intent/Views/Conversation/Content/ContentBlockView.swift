import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock
    var toolResult: ContentBlock?
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)?
    var isHydrating = false
    var onLayoutChange: (() -> Void)?
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

    static func decodeImageData(_ block: ContentBlock) -> Data? {
        block.data.flatMap { Data(base64Encoded: $0) }
    }

    static func decodeImage(_ block: ContentBlock) -> UIImage? {
        decodeImageData(block).flatMap { UIImage(data: $0) }
    }

    static func stripSuggestedPrompts(_ text: String) -> String {
        var result = SuggestedPrompts.stripBlocks(from: text)

        result = result.replacingOccurrences(
            of: "<!--(?![ \\t]*suggested-prompts[ \\t]*(\\r?\\n|$))[\\s\\S]*?-->",
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: "<agent_digest>[\\s\\S]*?</agent_digest>",
            with: "",
            options: .regularExpression
        )

        result = result.replacingOccurrences(
            of: "<supervisor>[\\s\\S]*?</supervisor>",
            with: "",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

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
    @ScaledMetric(relativeTo: .caption) private var contentIconSide: CGFloat = 12
    var disclosure = TranscriptDisclosure()
    private var thinkingExpanded: Bool {
        get { disclosure.binding(for: .thinking(block.id), default: false).wrappedValue }
        nonmutating set { disclosure.binding(for: .thinking(block.id), default: false).wrappedValue = newValue }
    }
    @State private var lightboxPresented = false
    @State private var pdfLink: PDFLinkPreviewView.Link?
    @State private var textLink: TextLinkPreviewView.Link?
    @State private var htmlLink: HTMLLinkPreviewView.Link?
    @State private var unopenableLink: UnopenableLink?
    @State private var lightboxPendingHydration = false

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
                        if block.inputTruncation.isTruncated { hydrate(block.id) }
                        if let toolResult, toolResult.outputTruncation.isTruncated { hydrate(toolResult.id) }
                    }
                }
            )

        case .toolResult:
            EmptyView()

        case .thinking:
            thinkingView

        case .image:
            imageView

        case .file:
            fileView

        case .resource:
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
                MarkdownTextView(text: text, onOpenURL: openTextURL, workspaceId: workspaceId, linkStyle: .chat)
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
        .unopenableLinkAlert($unopenableLink)
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
        case .unopenable(let reason):
            unopenableLink = UnopenableLink(url: url, reason: reason)
        case .system:
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
                Image(.thinking)
                    .resizable()
                    .scaledToFit()
                    .frame(width: contentIconSide, height: contentIconSide)
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

    private var imageNeedsHydration: Bool {
        block.dataTruncation.isTruncated && onHydrateBlock != nil
    }

    @ViewBuilder
    private var imageView: some View {
        if block.data == nil, !block.dataTruncation.isTruncated, let attachmentId = block.attachmentId {
            AttachmentReferenceImageView(
                workspaceId: workspaceId,
                attachmentId: attachmentId,
                style: .inline
            )
        } else if let uiImage = ContentBlockView.decodeImage(block) {
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
                if !block.dataTruncation.isTruncated {
                    ImageActionMenuItems(image: uiImage, originalData: imageData)
                }
            }
            .imageSaveAlert()
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: uiImage, data: imageData)
                    .coversConversationComposers()
            }
            .onChange(of: block.dataTruncation) { _, truncation in
                if !truncation.isTruncated, lightboxPendingHydration {
                    lightboxPendingHydration = false
                    composerFocus?.wrappedValue = false
                    lightboxPresented = true
                }
            }
            .onChange(of: isHydrating) { _, hydrating in
                if !hydrating, block.dataTruncation.isTruncated {
                    lightboxPendingHydration = false
                }
            }
        } else if block.dataTruncation.isTruncated {
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
                        Image(.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: contentIconSide, height: contentIconSide)
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
            Image(.file)
                .resizable()
                .scaledToFit()
                .frame(width: contentIconSide, height: contentIconSide)
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
        case unopenable(UnopenableLink.Reason)
        case system
    }

    static func textURLRoute(for url: URL, workspaceId: String) -> TextURLRoute {
        if let link = IntentFileLink.parse(url) ?? IntentFileLink.parsePath(url) {
            let target = link.workspaceId ?? workspaceId
            if WorkspacePDF.isPDF(path: link.path) {
                return .pdf(.init(workspaceId: target, path: link.path))
            }
            if ["html", "htm"].contains(URL(fileURLWithPath: link.path).pathExtension.lowercased()) {
                return .html(.init(workspaceId: target, path: link.path))
            }
            if !link.isImage, !WorkspaceVideo.isVideo(path: link.path) {
                return .text(.init(workspaceId: target, path: link.path))
            }
        }
        if let link = NoteDetailView.parseIntentNoteLink(url) {
            return .note(id: link.id, workspaceId: link.workspaceId ?? workspaceId)
        }
        if let reason = UnopenableLink.reason(for: url) {
            return .unopenable(reason)
        }
        return .system
    }
}
