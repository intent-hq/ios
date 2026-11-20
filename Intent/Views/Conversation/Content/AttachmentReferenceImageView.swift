import SwiftUI

struct AttachmentReferenceImageView: View {
    enum Style {
        case inline
        case thumbnail
    }

    let workspaceId: String
    let attachmentId: String
    let style: Style
    var loader: AttachmentImageLoader?
    @Environment(BackendSession.self) private var session: BackendSession?
    @Environment(\.colorScheme) var colorScheme
    @Environment(\.conversationComposerFocus) private var composerFocus
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0
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
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let image {
            Button {
                composerFocus?.wrappedValue = false
                lightboxPresented = true
            } label: {
                thumbnail(image)
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .contextMenu {
                ImageActionMenuItems(image: image)
            }
            .imageSaveAlert()
            .accessibilityLabel("Attached image")
            .fullScreenCover(isPresented: $lightboxPresented) {
                ImageLightboxView(image: image)
                    .coversConversationComposers()
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

    @ViewBuilder
    private func thumbnail(_ image: UIImage) -> some View {
        switch style {
        case .inline: InlineImageThumbnail(image: image)
        case .thumbnail: SquareImageThumbnail(image: image, side: side)
        }
    }

    private var side: CGFloat {
        switch style {
        case .inline: SquareImageThumbnail.transcriptSide
        case .thumbnail: ImageAttachmentThumbnail.side
        }
    }

    private func placeholder<Content: View>(@ViewBuilder _ label: () -> Content) -> some View {
        VStack(spacing: Constants.Conversation.ImagePlaceholder.loadingLabelSpacing) { label() }
            .font(.caption)
            .frame(width: side, height: side)
            .foregroundStyle(Theme.mutedForeground(for: colorScheme))
            .background(Theme.muted(for: colorScheme).opacity(Constants.Conversation.ImagePlaceholder.backgroundOpacity))
            .clipShape(RoundedRectangle(cornerRadius: Constants.Conversation.ImageThumbnail.cornerRadius))
    }
}
