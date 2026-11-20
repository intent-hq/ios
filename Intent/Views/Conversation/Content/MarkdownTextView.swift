import SwiftUI
import Textual

struct MarkdownTextView: View {
    let text: String
    var onOpenURL: ((URL) -> OpenURLAction.Result)?
    var workspaceId: String?
    var linkStyle: MarkdownLinkStyle
    private let markdownSource: String
    private let mermaidSources: [String: String]
    private let pendingDiagram: MermaidMarkdownContent.PendingDiagram?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.openURL) private var inheritedOpenURL
    @Environment(\.workspaceTranscriptDesign) private var workspaceDesign
    @Environment(\.assistantMessageStreaming) private var isStreaming
    @Environment(\.conversationComposerFocus) private var composerFocus
    @Environment(BackendSession.self) private var session: BackendSession?
    @State private var lightboxItem: LightboxItem?
    @State private var videoItem: VideoItem?
    @State private var pdfItem: PDFItem?
    @State private var browserItem: WorkspaceBrowser?
    @State private var unopenableLink: UnopenableLink?
    @State private var attachmentAttempt = 0

    private static let maximumBlockIndent = 3
    private static let indentedCodeWidth = 4
    private static let listContinuationIndent = 2
    private static let tabWidth = 4

    init(
        text: String,
        onOpenURL: ((URL) -> OpenURLAction.Result)? = nil,
        workspaceId: String? = nil,
        linkStyle: MarkdownLinkStyle = .plain
    ) {
        self.text = text
        self.onOpenURL = onOpenURL
        self.workspaceId = workspaceId
        self.linkStyle = linkStyle
        let prepared = MarkdownContentCache.shared.preparedContent(for: text)
        self.markdownSource = prepared.markdown
        self.mermaidSources = prepared.mermaidSources
        self.pendingDiagram = prepared.pendingDiagram
    }

    private var fileImageFetcher: @Sendable (String, String) async throws -> UIImage {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        return { workspaceId, path in
            try await fileLoader.image(workspaceId: workspaceId, path: path)
        }
    }

    static func assetMediaFetcher(session: BackendSession?) -> @Sendable (String, String) async throws -> WorkspaceFileMedia {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        return { workspaceId, assetId in
            try await fileLoader.assetMedia(workspaceId: workspaceId, assetId: assetId)
        }
    }

    private var fileVideoFetcher: @Sendable (String, String) async throws -> WorkspaceVideo {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        return { workspaceId, path in
            try await fileLoader.video(workspaceId: workspaceId, path: path)
        }
    }

    private var filePDFFetcher: @Sendable (String, String) async throws -> WorkspacePDF {
        let fileLoader = session?.workspaceFileImageLoader ?? .shared
        return { workspaceId, path in
            try await fileLoader.pdf(workspaceId: workspaceId, path: path)
        }
    }

    private var textColor: Color {
        workspaceDesign
            ? Constants.Conversation.Design.Palette.assistantForeground(for: colorScheme)
            : Theme.foreground(for: colorScheme)
    }

    private var parser: any MarkupParser {
        switch linkStyle {
        case .plain: MarkdownContentCache.shared
        case .chat: MarkdownContentCache.LinkRowsParser()
        }
    }

    var body: some View {
        let pending = isStreaming ? pendingDiagram : nil
        let markdownView = StructuredText(
            pending?.markdown ?? markdownSource,
            parser: parser
        )
            .textual.structuredTextStyle(CompactMarkdownStyle(
                mermaidSources: mermaidSources,
                pendingMermaidLanguage: pending?.language
            ))
            .textual.imageAttachmentLoader(
                IntentFileAttachmentLoader(
                    workspaceId: workspaceId,
                    fallback: .image(),
                    fileImage: fileImageFetcher,
                    assetMedia: Self.assetMediaFetcher(session: session),
                    fileVideo: fileVideoFetcher,
                    filePDF: filePDFFetcher
                )
            )
            .textual.listItemSpacing(
                .fontScaled(
                    top: Constants.Markdown.taskListTopSpacing / Constants.Markdown.baseFontSize,
                    bottom: Constants.Markdown.taskListBottomSpacing / Constants.Markdown.baseFontSize
                )
            )
            .textual.textSelection(.enabled)
            .textual.onAttachmentTap { attachment in
                if let image = Self.lightboxImage(for: attachment) {
                    composerFocus?.wrappedValue = false
                    lightboxItem = LightboxItem(image: image)
                } else if let video = Self.playbackVideo(for: attachment) {
                    videoItem = VideoItem(video: video)
                } else if let pdf = Self.previewPDF(for: attachment) {
                    pdfItem = PDFItem(pdf: pdf)
                } else if let failure = attachment.base as? IntentFilePDFFailureAttachment,
                          failure.prepareRetry(using: session?.workspaceFileImageLoader ?? .shared) {
                    attachmentAttempt += 1
                } else if let failure = attachment.base as? IntentFileVideoFailureAttachment,
                          failure.prepareRetry(using: session?.workspaceFileImageLoader ?? .shared) {
                    attachmentAttempt += 1
                } else if let failure = attachment.base as? IntentFileFailureAttachment,
                          failure.prepareRetry(using: session?.workspaceFileImageLoader ?? .shared) {
                    attachmentAttempt += 1
                }
            }
            .id(attachmentAttempt)
            .interFont(Constants.Typography.bodyS)
            .tracking(workspaceDesign ? Constants.Conversation.Design.Typography.bodyTracking : 0)
            .foregroundStyle(textColor)
            .tint(textColor)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fullScreenCover(item: $lightboxItem) { item in
                ImageLightboxView(image: item.image)
                    .coversConversationComposers()
            }
            .fullScreenCover(item: $videoItem) { item in
                VideoLightboxView(video: item.video)
                    .coversConversationComposers()
            }
            .fullScreenCover(item: $pdfItem) { item in
                PDFLightboxView(pdf: item.pdf)
                    .coversConversationComposers()
            }

        markdownView
            .environment(\.openURL, OpenURLAction(handler: openLink))
            .fullScreenCover(item: $browserItem) { browser in
                if let session {
                    WorkspaceBrowserView(browser: browser, connection: session.connection)
                        .coversConversationComposers()
                }
            }
            .unopenableLinkAlert($unopenableLink)
    }

    private func openLink(_ url: URL) -> OpenURLAction.Result {
        do {
            if let browser = try Self.workspaceBrowser(for: url, workspaceId: workspaceId, store: session?.browserStore) {
                browserItem = browser
                return .handled
            }
        } catch {
            unopenableLink = UnopenableLink(url: url, reason: .browserFailed(error.localizedDescription))
            return .handled
        }
        if let onOpenURL { return onOpenURL(url) }
        inheritedOpenURL(url)
        return .handled
    }

    static func workspaceBrowser(
        for url: URL,
        workspaceId: String?,
        store: WorkspaceBrowserStore?
    ) throws -> WorkspaceBrowser? {
        guard let workspaceId, !workspaceId.isEmpty, let store,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, WorkspaceBrowserURL.isLocalHost(host) else { return nil }
        return try store.open(workspaceId: workspaceId, url: url.absoluteString)
    }

    static func lightboxImage(for attachment: AnyAttachment) -> UIImage? {
        (attachment.base as? IntentFileImageAttachment)?.image
    }

    static func playbackVideo(for attachment: AnyAttachment) -> WorkspaceVideo? {
        (attachment.base as? IntentFileVideoAttachment)?.video
    }

    static func previewPDF(for attachment: AnyAttachment) -> WorkspacePDF? {
        (attachment.base as? IntentFilePDFAttachment)?.pdf
    }

    private static let taskListMarker =
        /^((?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+)\[([ xX])\][ \t]+/

    private static let listItemMarker =
        /^(?:[ \t]{0,3}>[ \t]?)*[ \t]*(?:[-*+]|[0-9]{1,9}[.)])[ \t]+\S/

    static func replacingTaskListMarkers(_ text: String) -> String {
        guard text.contains("[") else { return text }
        var codeFence: MarkdownCodeFence?
        var inList = false
        func replaceMarker(in line: String) -> String {
            let indent = leadingIndentWidth(of: line)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)

            if let fence = codeFence {
                if indent <= Self.maximumBlockIndent,
                   fence.closes(with: trimmed) {
                    codeFence = nil
                }
                return line
            }
            if indent <= Self.maximumBlockIndent || inList,
               let fence = MarkdownCodeFence(opening: trimmed) {
                codeFence = fence
                return line
            }
            if trimmed.isEmpty { return line }
            if indent >= Self.indentedCodeWidth, !inList { return line }

            if let match = line.prefixMatch(of: taskListMarker) {
                inList = true
                let box = match.output.2.lowercased() == "x" ? "☑" : "☐"
                return "\(match.output.1)\(box) \(line[match.range.upperBound...])"
            }
            if line.prefixMatch(of: listItemMarker) != nil {
                inList = true
            } else if indent < Self.listContinuationIndent {
                inList = false
            }
            return line
        }
        return text.components(separatedBy: "\n")
            .map(replaceMarker)
            .joined(separator: "\n")
    }

    private static func leadingIndentWidth(of line: String) -> Int {
        var width = 0
        for char in line {
            if char == " " {
                width += 1
            } else if char == "\t" {
                width += Self.tabWidth - width % Self.tabWidth
            } else {
                break
            }
        }
        return width
    }
}

private struct LightboxItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

private struct VideoItem: Identifiable {
    let id = UUID()
    let video: WorkspaceVideo
}

private struct PDFItem: Identifiable {
    let id = UUID()
    let pdf: WorkspacePDF
}
