import SwiftUI
import Textual

nonisolated enum MarkdownImageRoute: Equatable {
    case fallback
    case intentFile(IntentFileLink)
    case remote
    case workspaceAsset(WorkspaceAssetLink?)

    static func route(for url: URL) -> Self {
        if url.scheme?.lowercased() == "workspace-asset" {
            return .workspaceAsset(WorkspaceAssetLink.parse(url))
        }
        if let link = IntentFileLink.parse(url) {
            return .intentFile(link)
        }
        if let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            return .remote
        }
        return .fallback
    }
}

struct IntentFileAttachmentLoader<Fallback: AttachmentLoader>: AttachmentLoader {
    let workspaceId: String?
    let fallback: Fallback
    var remoteImage: @Sendable (URL) async throws -> UIImage = { url in
        try await RemoteImageLoader.shared.image(for: url)
    }
    var fileImage: @Sendable (_ workspaceId: String, _ path: String) async throws -> UIImage = { workspaceId, path in
        try await WorkspaceFileImageLoader.shared.image(workspaceId: workspaceId, path: path)
    }
    var assetMedia: @Sendable (String, String) async throws -> WorkspaceFileMedia = { workspaceId, assetId in
        try await WorkspaceFileImageLoader.shared.assetMedia(workspaceId: workspaceId, assetId: assetId)
    }
    var fileVideo: @Sendable (String, String) async throws -> WorkspaceVideo = { workspaceId, path in
        try await WorkspaceFileImageLoader.shared.video(workspaceId: workspaceId, path: path)
    }
    var filePDF: @Sendable (String, String) async throws -> WorkspacePDF = { workspaceId, path in
        try await WorkspaceFileImageLoader.shared.pdf(workspaceId: workspaceId, path: path)
    }

    func attachment(
        for url: URL,
        text: String,
        environment: ColorEnvironmentValues
    ) async throws -> AnyAttachment {
        try await resolvedAttachment(for: url, text: text) {
            AnyAttachment(
                try await fallback.attachment(for: url, text: text, environment: environment)
                    as any Textual.Attachment
            )
        }
    }

    func resolvedAttachment(
        for url: URL,
        text: String,
        fallback: () async throws -> AnyAttachment
    ) async throws -> AnyAttachment {
        switch MarkdownImageRoute.route(for: url) {
        case .workspaceAsset(let link):
            return await assetAttachment(link: link, text: text, url: url)
        case .intentFile(let link):
            if WorkspacePDF.isPDF(path: link.path) {
                return await pdfAttachment(link: link)
            }
            if WorkspaceVideo.isVideo(path: link.path) {
                return await videoAttachment(link: link, text: text)
            }
            return await imageAttachment(link: link, text: text, url: url)
        case .remote:
            if let attachment = await remoteImageAttachment(for: url, text: text) {
                return attachment
            }
            return try await fallback()
        case .fallback:
            return try await fallback()
        }
    }

    private func imageAttachment(link: IntentFileLink, text: String, url: URL) async -> AnyAttachment {
        guard link.isImage, let resolvedWorkspaceId = link.workspaceId ?? workspaceId else {
            return AnyAttachment(
                IntentFileFailureAttachment(altText: text) as any Textual.Attachment
            )
        }
        do {
            let image = try await fileImage(resolvedWorkspaceId, link.path)
            return AnyAttachment(
                IntentFileImageAttachment(image: image, altText: text, sourceURL: url)
                    as any Textual.Attachment
            )
        } catch {
            return AnyAttachment(
                IntentFileFailureAttachment(
                    altText: text,
                    retrySource: .file(workspaceId: resolvedWorkspaceId, path: link.path)
                ) as any Textual.Attachment
            )
        }
    }

    private func videoAttachment(link: IntentFileLink, text: String) async -> AnyAttachment {
        let resolvedWorkspaceId = link.workspaceId ?? workspaceId
        if let resolvedWorkspaceId,
           let video = try? await fileVideo(resolvedWorkspaceId, link.path) {
            return AnyAttachment(IntentFileVideoAttachment(video: video, name: text.isEmpty ?
                URL(fileURLWithPath: link.path).lastPathComponent : text) as any Textual.Attachment)
        }
        return videoFailure(path: link.path, retrySource: resolvedWorkspaceId.map { workspaceId in
            .file(workspaceId: workspaceId, path: link.path)
        })
    }

    private func pdfAttachment(link: IntentFileLink) async -> AnyAttachment {
        let resolvedWorkspaceId = link.workspaceId ?? workspaceId
        if let resolvedWorkspaceId,
           let pdf = try? await filePDF(resolvedWorkspaceId, link.path) {
            return AnyAttachment(IntentFilePDFAttachment(pdf: pdf) as any Textual.Attachment)
        }
        return AnyAttachment(IntentFilePDFFailureAttachment(
            name: URL(fileURLWithPath: link.path).lastPathComponent,
            workspaceId: resolvedWorkspaceId,
            path: link.path
        ) as any Textual.Attachment)
    }

    private func assetAttachment(link: WorkspaceAssetLink?, text: String, url: URL) async -> AnyAttachment {
        guard let link else {
            return AnyAttachment(IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
        }
        do {
            switch try await assetMedia(link.workspaceId, link.assetId) {
            case .image(let image):
                return AnyAttachment(
                    IntentFileImageAttachment(image: image, altText: text, sourceURL: url) as any Textual.Attachment
                )
            case .video(let video):
                return AnyAttachment(IntentFileVideoAttachment(video: video, name: text.isEmpty ?
                    link.assetId : text) as any Textual.Attachment)
            case .pdf, .text:
                return AnyAttachment(IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
            }
        } catch {
            if WorkspaceVideo.isVideo(path: link.assetId) || error as? WorkspaceFileImageLoader.LoadError == .notAVideo {
                return videoFailure(path: link.assetId, retrySource: .asset(
                    workspaceId: link.workspaceId, assetId: link.assetId
                ))
            }
            return AnyAttachment(IntentFileFailureAttachment(
                altText: text,
                retrySource: .asset(workspaceId: link.workspaceId, assetId: link.assetId)
            ) as any Textual.Attachment)
        }
    }

    private func videoFailure(path: String, retrySource: IntentFileVideoFailureAttachment.RetrySource?) -> AnyAttachment {
        AnyAttachment(IntentFileVideoFailureAttachment(
            name: URL(fileURLWithPath: path).lastPathComponent, retrySource: retrySource
        ) as any Textual.Attachment)
    }

    func remoteImageAttachment(for url: URL, text: String) async -> AnyAttachment? {
        guard let image = try? await remoteImage(url) else { return nil }
        return AnyAttachment(
            IntentFileImageAttachment(image: image, altText: text, sourceURL: url) as any Textual.Attachment
        )
    }
}

struct IntentFileImageAttachment: Attachment {
    let image: UIImage
    let altText: String
    var sourceURL: URL?

    var description: String { altText }

    var body: some View {
        InlineImageThumbnail(image: image)
            .accessibilityLabel(altText)
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
            .imageSaveAlert()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        InlineImageThumbnail.size(for: image.size, proposedWidth: proposal.width)
    }

    static func thumbnailSize(proposedWidth: CGFloat?) -> CGSize {
        let side = min(
            SquareImageThumbnail.transcriptSide,
            proposedWidth ?? SquareImageThumbnail.transcriptSide
        )
        return CGSize(width: side, height: side)
    }

    func pngData() -> Data? {
        image.pngData()
    }
}

struct IntentFileFailureAttachment: Attachment {
    let altText: String
    var retrySource: IntentFileVideoFailureAttachment.RetrySource?

    nonisolated init(altText: String, retrySource: IntentFileVideoFailureAttachment.RetrySource? = nil) {
        self.altText = altText
        self.retrySource = retrySource
    }

    var description: String { altText }

    var body: some View {
        ImageDecodeFailureView()
            .accessibilityHint("Retries loading the image", isEnabled: retrySource != nil)
            .accessibilityAddTraits(retrySource == nil ? [] : .isButton)
    }

    @MainActor
    func prepareRetry(using loader: WorkspaceFileImageLoader) -> Bool {
        switch retrySource {
        case let .asset(workspaceId, assetId):
            loader.forgetAssetFailure(workspaceId: workspaceId, assetId: assetId)
        case let .file(workspaceId, path):
            loader.forgetFailure(workspaceId: workspaceId, path: path)
        case nil:
            return false
        }
        return true
    }

    func sizeThatFits(_: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        let traits = UITraitCollection { mutableTraits in
            mutableTraits[UITraitPreferredContentSizeCategory.self] = UIContentSizeCategory(environment.dynamicTypeSize)
            mutableTraits[UITraitLegibilityWeight.self] = environment.legibilityWeight == .bold ? .bold : .regular
        }
        let font = Constants.Typography.subtextXXS.uiFont(compatibleWith: traits)
        let symbolHeight = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits).lineHeight
        let label = "Image".size(withAttributes: [.font: font])
        return CGSize(
            width: (label.width + symbolHeight + Constants.Conversation.ImagePlaceholder.failureLabelSpacing).rounded(.up),
            height: max(font.lineHeight, symbolHeight).rounded(.up)
        )
    }
}

private extension UIContentSizeCategory {
    nonisolated init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5:
            self = Self.accessibilityCategory(for: size)
        @unknown default: self = .large
        }
    }

    nonisolated private static func accessibilityCategory(
        for size: DynamicTypeSize
    ) -> UIContentSizeCategory {
        switch size {
        case .accessibility1: return .accessibilityMedium
        case .accessibility2: return .accessibilityLarge
        case .accessibility3: return .accessibilityExtraLarge
        case .accessibility4: return .accessibilityExtraExtraLarge
        case .accessibility5: return .accessibilityExtraExtraExtraLarge
        default: return .large
        }
    }
}
