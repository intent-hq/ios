import SwiftUI

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
    /// Explicit loader override (tests); when nil, the window session's
    /// loader is used, falling back to the shared (default-backend) loader.
    var loader: AttachmentImageLoader?
    /// The window's session, when present, so pinned windows resolve and
    /// fetch attachments over their own backend connection.
    @Environment(BackendSession.self) private var session: BackendSession?
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
    @ScaledMetric(relativeTo: .caption) private var retryIconSide: CGFloat = 12

    var body: some View {
        content
            .task(id: "\(workspaceId)|\(attachmentId)|\(attempt)") {
                let key = "\(workspaceId)|\(attachmentId)"
                if loadedKey != key { image = nil }
                guard image == nil else { return }
                failed = false
                let loader = loader ?? session?.attachmentImageLoader ?? .shared
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
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
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
                    Image(.clockwiseArrow)
                        .resizable()
                        .scaledToFit()
                        .frame(width: retryIconSide, height: retryIconSide)
                    if style == .inline {
                        Text("Tap to retry")
                            .interFont(Constants.Typography.subtextXXS)
                    }
                }
                .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .accessibilityLabel("Retry loading image")
        } else {
            placeholder {
                ProgressView()
                    .controlSize(.mini)
                if style == .inline {
                    Text("Loading image…")
                        .interFont(Constants.Typography.subtextXXS)
                }
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
        VStack(spacing: Constants.Conversation.ImagePlaceholder.loadingLabelSpacing) { label() }
            .font(.caption)
            .frame(width: side, height: side)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.ImagePlaceholder.backgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
    }
}
