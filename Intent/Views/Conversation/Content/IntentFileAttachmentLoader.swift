import SwiftUI
import Textual

/// Routes intent-file and saved-asset Markdown images through the daemon,
/// remote http(s) URLs through `RemoteImageLoader`, and everything else
/// through the wrapped fallback loader.
///
/// Cleartext `http` is claimed deliberately: ATS (`NSAllowsLocalNetworking`
/// only) permits local-network http — e.g. images served by the daemon at
/// 127.0.0.1 — which therefore load and get the lightbox. Non-local http
/// fails ATS inside `RemoteImageLoader` and falls through to the fallback
/// loader, which shares URLSession's ATS policy and fails the same way, so
/// routing it here loses nothing.
nonisolated enum MarkdownImageRoute: Equatable {
    case fallback
    case intentFile(IntentFileLink)
    case remote
    case workspaceAsset(WorkspaceAssetLink?)

    static func route(for url: URL) -> Self {
        // Claim malformed saved-asset URLs too, so they fail locally instead
        // of reaching Textual's network fallback.
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

/// Textual image-attachment loader that renders `![alt](intent://local/[ws-id/]file/<path>)`
/// images/videos/PDFs and `workspace-asset://` media by fetching bytes from the daemon,
/// and remote http(s) images via `RemoteImageLoader`. Videos open full-screen
/// playback; images open the lightbox. Other URLs use the wrapped fallback loader
/// (Textual's default network loader).
///
/// Never throws for intent-file or saved-asset links — failures degrade to
/// a placeholder attachment without breaking the surrounding text.
/// Failed remote loads fall through to the fallback loader, preserving its
/// behavior for broken URLs.
struct IntentFileAttachmentLoader<Fallback: AttachmentLoader>: AttachmentLoader {
    /// Workspace resolving short-form links (no workspace segment in the URL).
    let workspaceId: String?
    let fallback: Fallback
    /// Fetches and decodes a remote http(s) image; injectable for tests.
    var remoteImage: @Sendable (URL) async throws -> UIImage = { url in
        try await RemoteImageLoader.shared.image(for: url)
    }
    /// Fetches an intent-file image from the daemon; injectable so a window
    /// routes through its session's `WorkspaceFileImageLoader` instead of the
    /// shared (default-backend) loader.
    var fileImage: @Sendable (_ workspaceId: String, _ path: String) async throws -> UIImage = { workspaceId, path in
        try await WorkspaceFileImageLoader.shared.image(workspaceId: workspaceId, path: path)
    }
    /// Saved assets use the same session-bound loader, cache and decode limits.
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
        // The `as any Textual.Attachment` cast pins AnyAttachment's
        // existential initializer: newer compilers (Xcode 26.x) treat the
        // `some`/`any` overload pair as ambiguous for concrete arguments.
        // Module-qualified because inside this type `Attachment` resolves to
        // the AttachmentLoader associated type (AnyAttachment), not the
        // protocol.
        try await resolvedAttachment(for: url, text: text) {
            AnyAttachment(
                try await fallback.attachment(for: url, text: text, environment: environment)
                    as any Textual.Attachment
            )
        }
    }

    /// Environment-free core of `attachment(for:)`, testable without a
    /// `ColorEnvironmentValues` (whose initializer is internal to Textual):
    /// the fallback loader invocation is passed in as a closure.
    func resolvedAttachment(
        for url: URL,
        text: String,
        fallback: () async throws -> AnyAttachment
    ) async throws -> AnyAttachment {
        switch MarkdownImageRoute.route(for: url) {
        case .workspaceAsset(let link):
            return await assetAttachment(link: link, text: text)
        case .intentFile(let link):
            if WorkspacePDF.isPDF(path: link.path) {
                return await pdfAttachment(link: link)
            }
            if WorkspaceVideo.isVideo(path: link.path) {
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
            guard link.isImage, let resolvedWorkspaceId = link.workspaceId ?? workspaceId else {
                return AnyAttachment(
                    IntentFileFailureAttachment(altText: text) as any Textual.Attachment
                )
            }
            do {
                let image = try await fileImage(resolvedWorkspaceId, link.path)
                return AnyAttachment(
                    IntentFileImageAttachment(image: image, altText: text)
                        as any Textual.Attachment
                )
            } catch {
                return AnyAttachment(
                    IntentFileFailureAttachment(altText: text) as any Textual.Attachment
                )
            }
        case .remote:
            if let attachment = await remoteImageAttachment(for: url, text: text) {
                return attachment
            }
            return try await fallback()
        case .fallback:
            return try await fallback()
        }
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

    private func assetAttachment(link: WorkspaceAssetLink?, text: String) async -> AnyAttachment {
        guard let link else {
            return AnyAttachment(IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
        }
        do {
            switch try await assetMedia(link.workspaceId, link.assetId) {
            case .image(let image):
                return AnyAttachment(IntentFileImageAttachment(image: image, altText: text) as any Textual.Attachment)
            case .video(let video):
                return AnyAttachment(IntentFileVideoAttachment(video: video, name: text.isEmpty ?
                    link.assetId : text) as any Textual.Attachment)
            case .pdf, .text:
                // Saved-asset documents are not supported by this attachment route.
                return AnyAttachment(IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
            }
        } catch {
            if WorkspaceVideo.isVideo(path: link.assetId) || error as? WorkspaceFileImageLoader.LoadError == .notAVideo {
                return videoFailure(path: link.assetId, retrySource: .asset(
                    workspaceId: link.workspaceId, assetId: link.assetId
                ))
            }
            return AnyAttachment(IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
        }
    }

    private func videoFailure(path: String, retrySource: IntentFileVideoFailureAttachment.RetrySource?) -> AnyAttachment {
        AnyAttachment(IntentFileVideoFailureAttachment(
            name: URL(fileURLWithPath: path).lastPathComponent, retrySource: retrySource
        ) as any Textual.Attachment)
    }

    /// Loaded remote image wrapped in the lightbox-capable attachment; nil on
    /// fetch/decode failure so the remote route falls through to the wrapped
    /// fallback loader.
    func remoteImageAttachment(for url: URL, text: String) async -> AnyAttachment? {
        guard let image = try? await remoteImage(url) else { return nil }
        return AnyAttachment(
            IntentFileImageAttachment(image: image, altText: text) as any Textual.Attachment
        )
    }
}

/// A loaded markdown image (intent-file, saved asset or remote http(s)) embedded in text;
/// taps are routed by `MarkdownTextView`'s attachment tap handler to open the
/// lightbox.
struct IntentFileImageAttachment: Attachment {
    let image: UIImage
    let altText: String

    var description: String { altText }

    var body: some View {
        IntentFileAttachmentImageView(image: image, accessibilityLabel: altText)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        Self.thumbnailSize(proposedWidth: proposal.width)
    }

    /// Fixed square transcript thumbnail (FE parity), clamped to the
    /// proposed width so narrow layouts don't overflow.
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

/// Placeholder attachment for non-image extensions, missing workspace, and
/// fetch/decode failures.
struct IntentFileFailureAttachment: Attachment {
    let altText: String

    var description: String { altText }

    var body: some View {
        ImageDecodeFailureView()
    }

    func sizeThatFits(_: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        // Match the Inter label and native SF Symbol at the current text traits.
        // Typed setters support Textual's off-main measurement without actor-isolated property access.
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

/// Rendering for a loaded attachment image, cropped to fill the square
/// frame Textual derives from `sizeThatFits`; tap handling lives in
/// `MarkdownTextView` via the Textual attachment tap action.
private struct IntentFileAttachmentImageView: View {
    let image: UIImage
    let accessibilityLabel: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel(accessibilityLabel)
            )
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius)
                    .strokeBorder(
                        Theme.border(for: colorScheme),
                        lineWidth: Constants.Conversation.ImageThumbnail.borderWidth
                    )
            )
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
    }
}
