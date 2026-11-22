import SwiftUI

struct ImageLightboxItem: Identifiable, Equatable {
    enum Source: Equatable {
        case loaded(UIImage, Data?)
        case inline(ContentBlock)
        case attachment(workspaceId: String, attachmentId: String)
    }

    let id: String
    var messageId: String?
    let source: Source

    var loadKey: String {
        switch source {
        case .loaded:
            id
        case let .inline(block):
            "\(id)|\(block.dataTruncation.isTruncated)|\(block.data?.count ?? 0)"
        case let .attachment(workspaceId, attachmentId):
            "\(workspaceId)|\(attachmentId)"
        }
    }

    var isTruncated: Bool {
        if case let .inline(block) = source { return block.dataTruncation.isTruncated }
        return false
    }
}

struct ConversationImageGallery {
    let store: ConversationStore
    let workspaceId: String

    var items: [ImageLightboxItem] {
        var seen = Set<String>()
        return store.messages.flatMap { message in
            message.contentBlocks.compactMap { block in
                Self.item(for: block, messageId: message.id, workspaceId: workspaceId)
            }
        }
        .filter { seen.insert($0.id).inserted }
    }

    static func item(for block: ContentBlock, messageId: String?, workspaceId: String) -> ImageLightboxItem? {
        guard block.type == .image else { return nil }
        if block.data == nil, !block.dataTruncation.isTruncated, let attachmentId = block.attachmentId {
            return ImageLightboxItem(
                id: block.id,
                messageId: messageId,
                source: .attachment(workspaceId: workspaceId, attachmentId: attachmentId)
            )
        }
        guard block.data != nil else { return nil }
        return ImageLightboxItem(id: block.id, messageId: messageId, source: .inline(block))
    }

    func hydrate(_ item: ImageLightboxItem) {
        guard item.isTruncated, let messageId = item.messageId,
              !store.hydratingBlockIds(forMessage: messageId).contains(item.id) else { return }
        let store = store
        Task { await store.hydrateBlock(messageId: messageId, blockId: item.id) }
    }
}

extension EnvironmentValues {
    @Entry var conversationImageGallery: ConversationImageGallery?
}

struct GalleryImageLightbox: View {
    let itemID: String
    let image: UIImage
    var data: Data?
    let gallery: ConversationImageGallery?

    var body: some View {
        let fallback = ImageLightboxItem(id: itemID, source: .loaded(image, data))
        let items = gallery?.items ?? []
        ImageLightboxView(
            items: items.contains { $0.id == itemID } ? items : [fallback],
            initialID: itemID,
            initialImage: (image, data),
            onHydrate: gallery?.hydrate
        )
    }
}
