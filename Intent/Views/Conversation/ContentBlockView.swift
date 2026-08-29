import SwiftUI

struct ContentBlockView: View {
    let block: ContentBlock
    let allBlocks: [ContentBlock]
    let workspaceId: String
    var onNavigateToNote: ((_ noteId: String, _ workspaceId: String, _ noteTitle: String) -> Void)? = nil
    /// Block ids of this message with an agent.getMessageBlock hydration
    /// fetch in flight (slim projection, PROTOCOL §5.5).
    var hydratingBlockIds: Set<String> = []
    /// Fetch the full body of a slim-truncated block by id; absent → no
    /// hydration (bounded previews stay).
    var onHydrateBlock: ((_ blockId: String) -> Void)? = nil
    @EnvironmentObject var coordinator: AppCoordinator
    @Environment(\.colorScheme) var colorScheme
    @State private var thinkingExpanded = false
    @State private var lightboxPresented = false
    /// Set when a thumbnail tap started hydration: the lightbox then opens
    /// automatically once the full block merges in (dataTruncated clears).
    @State private var lightboxPendingHydration = false

    var body: some View {
        switch block.type {
        case .text:
            if let text = block.resolvedText {
                let cleaned = Self.stripSuggestedPrompts(text)
                if !cleaned.isEmpty {
                    MarkdownTextView(text: cleaned, onOpenURL: { url in
                        if let link = NoteDetailView.parseIntentNoteLink(url) {
                            let targetWorkspaceId = link.workspaceId ?? workspaceId
                            if let onNavigateToNote = onNavigateToNote {
                                onNavigateToNote(link.id, targetWorkspaceId, "Note")
                            } else {
                                coordinator.onSelectNote(link.id, workspaceId: targetWorkspaceId, noteTitle: "Note")
                            }
                            return .handled
                        }
                        return .systemAction
                    }, workspaceId: workspaceId)
                }
            }

        case .code:
            CodeBlockView(
                code: block.resolvedText ?? "",
                language: block.language
            )

        case .toolUse:
            let result = findToolResult(for: block)
            ToolCallView(
                block: block,
                toolResult: result,
                isHydrating: hydratingBlockIds.contains(block.id)
                    || (result.map { hydratingBlockIds.contains($0.id) } ?? false),
                onHydrate: onHydrateBlock.map { hydrate in
                    {
                        // Hydrate whichever side of the row was truncated
                        // (input and output are separate persisted blocks).
                        if block.inputTruncated == true { hydrate(block.id) }
                        if let result, result.outputTruncated == true { hydrate(result.id) }
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
        DisclosureGroup(isExpanded: $thinkingExpanded) {
            Text(block.resolvedText ?? "")
                .font(.callout)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "brain")
                    .font(.caption)
                Text("Thinking")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        }
        .tint(Theme.mutedForeground(for: colorScheme))
    }

    /// A slim-truncated image asks for the original on tap (PROTOCOL §5.5);
    /// the lightbox opens once hydration swaps the full block in (the
    /// truncation flag then disappears from the merged block).
    private var imageNeedsHydration: Bool {
        block.dataTruncated == true && onHydrateBlock != nil
    }

    private var isHydratingImage: Bool {
        hydratingBlockIds.contains(block.id)
    }

    @ViewBuilder
    private var imageView: some View {
        if block.data == nil, block.dataTruncated != true, let attachmentId = block.attachmentId {
            // Attachment-reference block (PROTOCOL §5.5): no inline bytes —
            // resolve the registry row and fetch via file.readChunk.
            AttachmentReferenceImageView(
                workspaceId: workspaceId, attachmentId: attachmentId, style: .inline)
        } else if let uiImage = Self.decodeImage(block) {
            // Full image, or the write-time thumbnail served by the slim
            // projection (dataIsThumbnail) — tapping a thumbnail hydrates.
            let imageData = Self.decodeImageData(block)
            Button {
                if imageNeedsHydration {
                    lightboxPendingHydration = true
                    onHydrateBlock?(block.id)
                } else {
                    lightboxPresented = true
                }
            } label: {
                SquareImageThumbnail(image: uiImage, side: SquareImageThumbnail.transcriptSide)
                    .opacity(isHydratingImage ? 0.6 : 1)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ImageActionMenuItems(image: uiImage, originalData: imageData)
            }
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: uiImage, data: imageData)
            }
            .onChange(of: block.dataTruncated) { _, truncated in
                // Hydration merged the full block in (the truncation flag
                // cleared): open the lightbox the tap asked for.
                if truncated != true && lightboxPendingHydration {
                    lightboxPendingHydration = false
                    lightboxPresented = true
                }
            }
            .onChange(of: isHydratingImage) { _, hydrating in
                // Fetch settled without clearing the flag (failure): drop the
                // pending open so a later unrelated merge can't surprise-open.
                if !hydrating && block.dataTruncated == true {
                    lightboxPendingHydration = false
                }
            }
        } else if block.dataTruncated == true {
            // Slim row with no persisted thumbnail (legacy rows, failed
            // generation): placeholder chip with the same on-demand fetch.
            Button {
                onHydrateBlock?(block.id)
            } label: {
                HStack(spacing: 4) {
                    if isHydratingImage {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Loading image…")
                    } else {
                        Image(systemName: "photo")
                        Text(imageNeedsHydration ? "Tap to load image" : "Image")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            }
            .buttonStyle(.plain)
            .disabled(!imageNeedsHydration || isHydratingImage)
        } else {
            ImageDecodeFailureView()
        }
    }

    @ViewBuilder
    private var fileView: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc")
                .font(.caption)
            Text(block.fileName ?? "File")
                .font(.caption.monospaced())
        }
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.muted(for: colorScheme).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
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

    private func findToolResult(for toolUseBlock: ContentBlock) -> ContentBlock? {
        guard let toolUseId = toolUseBlock.resolvedToolUseId ?? toolUseBlock.toolCallId else { return nil }
        return allBlocks.first { $0.type == .toolResult && ($0.resolvedToolUseId == toolUseId || $0.toolCallId == toolUseId) }
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

/// Decode-failure fallback shared by inline images and attachment thumbnails.
struct ImageDecodeFailureView: View {
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "photo")
            Text("Image")
        }
        .font(.caption)
        .foregroundStyle(Theme.mutedForeground(for: colorScheme))
    }
}

/// Square rounded thumbnail for a user-attached image block; tapping opens
/// the fullscreen lightbox (FE parity: ChatMessage.svelte attached images).
struct ImageAttachmentThumbnail: View {
    let block: ContentBlock
    let workspaceId: String
    @State private var lightboxPresented = false

    static let side: CGFloat = 60

    var body: some View {
        if block.data == nil, let attachmentId = block.attachmentId {
            // Attachment-reference block (PROTOCOL §5.5): fetch the bytes
            // from the workspace's attachment store.
            AttachmentReferenceImageView(
                workspaceId: workspaceId, attachmentId: attachmentId, style: .thumbnail)
        } else if let uiImage = ContentBlockView.decodeImage(block) {
            let imageData = ContentBlockView.decodeImageData(block)
            Button { lightboxPresented = true } label: {
                SquareImageThumbnail(image: uiImage, side: Self.side)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ImageActionMenuItems(image: uiImage, originalData: imageData)
            }
            .accessibilityLabel("Attached image")
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: uiImage, data: imageData)
            }
        } else {
            ImageDecodeFailureView()
        }
    }
}

/// Renders an attachment-reference image block (`attachmentId`, no inline
/// `data`): resolves and fetches asynchronously via `AttachmentImageLoader`,
/// showing a loading placeholder, then the image (tap → lightbox), or a
/// tap-to-retry placeholder on failure.
struct AttachmentReferenceImageView: View {
    enum Style {
        /// Assistant-row inline rendering: large fixed square thumbnail.
        case inline
        /// User-row attachment grid: small fixed square thumbnail.
        case thumbnail
    }

    let workspaceId: String
    let attachmentId: String
    let style: Style
    var loader: AttachmentImageLoader = .shared
    @Environment(\.colorScheme) var colorScheme
    @State private var image: UIImage?
    @State private var failed = false
    /// Bumped on retry taps so the `.task(id:)` re-runs the fetch.
    @State private var attempt = 0
    /// The workspace|attachment key `image` was loaded for — if view
    /// identity is ever reused for a different attachment, the mismatch
    /// resets the latch so the stale image can't survive the guard below.
    @State private var loadedKey: String?
    @State private var lightboxPresented = false

    var body: some View {
        content
            .task(id: "\(workspaceId)|\(attachmentId)|\(attempt)") {
                let key = "\(workspaceId)|\(attachmentId)"
                if loadedKey != key { image = nil }
                guard image == nil else { return }
                failed = false
                do {
                    let loaded = attempt == 0
                        ? try await loader.image(workspaceId: workspaceId, attachmentId: attachmentId)
                        : try await loader.retryImage(workspaceId: workspaceId, attachmentId: attachmentId)
                    image = loaded
                    loadedKey = key
                } catch is CancellationError {
                    // View scrolled away mid-fetch; not a failure.
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button { lightboxPresented = true } label: {
                SquareImageThumbnail(image: image, side: side)
            }
            .buttonStyle(.plain)
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
            .accessibilityLabel("Attached image")
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: image)
            }
        } else if failed {
            Button { attempt += 1 } label: {
                placeholder {
                    Image(systemName: "arrow.clockwise")
                    if style == .inline { Text("Tap to retry") }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Retry loading image")
        } else {
            placeholder {
                ProgressView()
                    .controlSize(.mini)
                if style == .inline { Text("Loading image…") }
            }
        }
    }

    /// Rendered side for this style: transcript-size square for inline
    /// images, the small user-row square for attachment-grid thumbnails.
    private var side: CGFloat {
        switch style {
        case .inline: SquareImageThumbnail.transcriptSide
        case .thumbnail: ImageAttachmentThumbnail.side
        }
    }

    /// Placeholder square sized to match the eventual rendering.
    private func placeholder<Content: View>(@ViewBuilder _ label: () -> Content) -> some View {
        VStack(spacing: 2) { label() }
            .font(.caption)
            .frame(width: side, height: side)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .background(Theme.muted(for: colorScheme).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

