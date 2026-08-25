import SwiftUI
import Textual

/// Textual image-attachment loader that renders `![alt](intent://local/[ws-id/]file/<path>)`
/// images by fetching the file's bytes from the daemon; every other URL falls
/// through to the wrapped fallback loader (Textual's default network loader).
///
/// Never throws for intent-file links — one failed attachment must not break
/// the surrounding text, so failures degrade to a placeholder attachment.
struct IntentFileAttachmentLoader<Fallback: AttachmentLoader>: AttachmentLoader {
    /// Workspace resolving short-form links (no workspace segment in the URL).
    let workspaceId: String?
    let fallback: Fallback

    func attachment(
        for url: URL,
        text: String,
        environment: ColorEnvironmentValues
    ) async throws -> AnyAttachment {
        // The `as any Textual.Attachment` casts pin AnyAttachment's
        // existential initializer: newer compilers (Xcode 26.x) treat the
        // `some`/`any` overload pair as ambiguous for concrete arguments.
        // Module-qualified because inside this type `Attachment` resolves to
        // the AttachmentLoader associated type (AnyAttachment), not the
        // protocol.
        guard let link = IntentFileLink.parse(url) else {
            return AnyAttachment(
                try await fallback.attachment(for: url, text: text, environment: environment)
                    as any Textual.Attachment)
        }
        guard link.isImage, let ws = link.workspaceId ?? workspaceId else {
            return AnyAttachment(
                IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
        }
        do {
            let image = try await WorkspaceFileImageLoader.shared.image(
                workspaceId: ws, path: link.path)
            return AnyAttachment(
                IntentFileImageAttachment(image: image, altText: text) as any Textual.Attachment)
        } catch {
            return AnyAttachment(
                IntentFileFailureAttachment(altText: text) as any Textual.Attachment)
        }
    }
}

/// A loaded intent-file image embedded in text; tapping opens the lightbox.
struct IntentFileImageAttachment: Attachment {
    let image: UIImage
    let altText: String

    /// Cap matching the previous MarkdownUI rendering.
    static let maxHeight: CGFloat = 300

    var description: String { altText }

    var body: some View {
        IntentFileAttachmentImageView(image: image)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, in _: TextEnvironmentValues) -> CGSize {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return size }
        let aspect = size.width / size.height
        var width = min(proposal.width ?? size.width, size.width)
        var height = width / aspect
        if height > Self.maxHeight {
            height = Self.maxHeight
            width = height * aspect
        }
        return CGSize(width: width, height: height)
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
    fileprivate init(_ size: DynamicTypeSize) {
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

/// Tap-for-lightbox wrapper around a loaded attachment image.
private struct IntentFileAttachmentImageView: View {
    let image: UIImage
    @State private var lightboxPresented = false

    var body: some View {
        Button { lightboxPresented = true } label: {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .fullScreenCover(isPresented: $lightboxPresented) {
            ImageLightboxView(image: image)
        }
    }
}
