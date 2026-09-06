import SwiftUI
import Textual

/// Routing decision for a markdown-image URL: intent-file links are served
/// from the daemon, remote http(s) URLs from `RemoteImageLoader`, everything
/// else from the wrapped fallback loader.
///
/// Cleartext `http` is claimed deliberately: ATS (`NSAllowsLocalNetworking`
/// only) permits local-network http — e.g. images served by the daemon at
/// 127.0.0.1 — which therefore load and get the lightbox. Non-local http
/// fails ATS inside `RemoteImageLoader` and falls through to the fallback
/// loader, which shares URLSession's ATS policy and fails the same way, so
/// routing it here loses nothing.
nonisolated enum MarkdownImageRoute: Equatable {
    case intentFile(IntentFileLink)
    case remote
    case fallback

    static func route(for url: URL) -> MarkdownImageRoute {
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
/// images by fetching the file's bytes from the daemon and remote http(s)
/// images via `RemoteImageLoader`, so both open the lightbox on tap; every
/// other URL falls through to the wrapped fallback loader (Textual's default
/// network loader).
///
/// Never throws for intent-file links — one failed attachment must not break
/// the surrounding text, so failures degrade to a placeholder attachment.
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
    var fileImage: @Sendable (_ workspaceId: String, _ path: String) async throws -> UIImage = {
        workspaceId, path in
        try await WorkspaceFileImageLoader.shared.image(workspaceId: workspaceId, path: path)
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
                    as any Textual.Attachment)
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
        case .intentFile(let link):
            guard link.isImage, let ws = link.workspaceId ?? workspaceId else {
                return AnyAttachment(
                    IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
            }
            do {
                let image = try await fileImage(ws, link.path)
                return AnyAttachment(
                    IntentFileImageAttachment(image: image, altText: text)
                        as any Textual.Attachment)
            } catch {
                return AnyAttachment(
                    IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
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

    /// Loaded remote image wrapped in the lightbox-capable attachment; nil on
    /// fetch/decode failure so the remote route falls through to the wrapped
    /// fallback loader.
    func remoteImageAttachment(for url: URL, text: String) async -> AnyAttachment? {
        guard let image = try? await remoteImage(url) else { return nil }
        return AnyAttachment(
            IntentFileImageAttachment(image: image, altText: text) as any Textual.Attachment)
    }
}

/// A loaded markdown image (intent-file or remote http(s)) embedded in text;
/// taps are routed by `MarkdownTextView`'s attachment tap handler to open the
/// lightbox.
struct IntentFileImageAttachment: Attachment {
    let image: UIImage
    let altText: String

    var description: String { altText }

    var body: some View {
        IntentFileAttachmentImageView(image: image)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        Self.thumbnailSize(proposedWidth: proposal.width)
    }

    /// Fixed square transcript thumbnail (FE parity), clamped to the
    /// proposed width so narrow layouts don't overflow.
    static func thumbnailSize(proposedWidth: CGFloat?) -> CGSize {
        let side = min(SquareImageThumbnail.transcriptSide,
                       proposedWidth ?? SquareImageThumbnail.transcriptSide)
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

    func sizeThatFits(_ proposal: ProposedViewSize, in environment: TextEnvironmentValues) -> CGSize {
        // Match ImageDecodeFailureView's intrinsic size (SF Symbol + caption
        // label in a 4pt-spaced HStack) at the current Dynamic Type size.
        let traits = UITraitCollection(
            preferredContentSizeCategory: UIContentSizeCategory(environment.dynamicTypeSize))
        let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: traits)
        let label = ("Image" as NSString).size(withAttributes: [.font: font])
        return CGSize(
            width: (label.width + font.lineHeight + 4).rounded(.up),
            height: font.lineHeight.rounded(.up))
    }
}

extension UIContentSizeCategory {
    fileprivate nonisolated init(_ size: DynamicTypeSize) {
        switch size {
        case .xSmall: self = .extraSmall
        case .small: self = .small
        case .medium: self = .medium
        case .large: self = .large
        case .xLarge: self = .extraLarge
        case .xxLarge: self = .extraExtraLarge
        case .xxxLarge: self = .extraExtraExtraLarge
        case .accessibility1: self = .accessibilityMedium
        case .accessibility2: self = .accessibilityLarge
        case .accessibility3: self = .accessibilityExtraLarge
        case .accessibility4: self = .accessibilityExtraExtraLarge
        case .accessibility5: self = .accessibilityExtraExtraExtraLarge
        @unknown default: self = .large
        }
    }
}

/// Rendering for a loaded attachment image, cropped to fill the square
/// frame Textual derives from `sizeThatFits`; tap handling lives in
/// `MarkdownTextView` via the Textual attachment tap action.
private struct IntentFileAttachmentImageView: View {
    let image: UIImage
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Color.clear
            .overlay(
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            )
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius)
                    .strokeBorder(
                        Theme.border(for: colorScheme),
                        lineWidth: Constants.Conversation.ImageThumbnail.borderWidth)
            )
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
    }
}
