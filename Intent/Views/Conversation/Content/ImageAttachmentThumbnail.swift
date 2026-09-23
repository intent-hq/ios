import SwiftUI

/// Square rounded thumbnail for a user-attached image block; tapping opens
/// the fullscreen lightbox (FE parity: ChatMessage.svelte attached images).
struct ImageAttachmentThumbnail: View {
    let block: ContentBlock
    let workspaceId: String
    @State private var lightboxPresented = false

    static let side: CGFloat = Constants.Conversation.ImageThumbnail.attachmentSide

    var body: some View {
        if block.data == nil, let attachmentId = block.attachmentId {
            // Attachment-reference block (PROTOCOL §5.5): fetch the bytes
            // from the workspace's attachment store.
            AttachmentReferenceImageView(
                workspaceId: workspaceId,
                attachmentId: attachmentId,
                style: .thumbnail
            )
        } else if let uiImage = ContentBlockView.decodeImage(block) {
            let imageData = ContentBlockView.decodeImageData(block)
            Button { lightboxPresented = true } label: {
                SquareImageThumbnail(image: uiImage, side: Self.side)
                    .copyContextMenuPassthrough()
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
