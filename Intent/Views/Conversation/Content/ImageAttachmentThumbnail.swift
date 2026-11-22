import SwiftUI

struct ImageAttachmentThumbnail: View {
    let block: ContentBlock
    let workspaceId: String
    @Environment(\.conversationComposerFocus) private var composerFocus
    @Environment(\.conversationImageGallery) private var gallery
    @State private var lightboxPresented = false

    static let side: CGFloat = Constants.Conversation.ImageThumbnail.attachmentSide

    var body: some View {
        if block.data == nil, let attachmentId = block.attachmentId {
            AttachmentReferenceImageView(
                workspaceId: workspaceId,
                attachmentId: attachmentId,
                style: .thumbnail,
                galleryItemID: block.id
            )
        } else if let uiImage = ContentBlockView.decodeImage(block) {
            let imageData = ContentBlockView.decodeImageData(block)
            Button {
                composerFocus?.wrappedValue = false
                lightboxPresented = true
            } label: {
                SquareImageThumbnail(image: uiImage, side: Self.side)
                    .copyContextMenuPassthrough()
            }
            .buttonStyle(IntentContentButtonStyle())
            .contextMenu {
                ImageActionMenuItems(image: uiImage, originalData: imageData)
            }
            .imageSaveAlert()
            .accessibilityLabel("Attached image")
            .fullScreenCover(isPresented: $lightboxPresented) {
                GalleryImageLightbox(itemID: block.id, image: uiImage, data: imageData, gallery: gallery)
                    .coversConversationComposers()
            }
        } else {
            ImageDecodeFailureView()
        }
    }
}
