import SwiftUI

struct ImageLightboxItem: Identifiable, Equatable {
    enum Source: Equatable {
        case loaded(UIImage, Data?)
        case inline(ContentBlock)
        case attachment(workspaceId: String, attachmentId: String)
        case markdown(URL, workspaceId: String, blockId: String)
    }

    let id: String
    var messageId: String?
    let source: Source

    func isMarkdownImage(_ url: URL, inBlock blockId: String) -> Bool {
        if case let .markdown(itemURL, _, itemBlockId) = source { return itemURL == url && itemBlockId == blockId }
        return false
    }

    var loadKey: String {
        switch source {
        case .loaded:
            id
        case let .inline(block):
            "\(id)|\(block.dataTruncation.isTruncated)|\(block.data?.count ?? 0)"
        case let .attachment(workspaceId, attachmentId):
            "\(workspaceId)|\(attachmentId)"
        case let .markdown(url, workspaceId, _):
            "\(workspaceId)|\(url.absoluteString)"
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
            message.contentBlocks.flatMap { block -> [ImageLightboxItem] in
                if block.type == .text, message.role != .user {
                    return Self.markdownItems(in: block, messageId: message.id, workspaceId: workspaceId)
                }
                return Self.item(for: block, messageId: message.id, workspaceId: workspaceId).map { [$0] } ?? []
            }
        }
        .filter { seen.insert($0.id).inserted }
    }

    func markdownItemID(for url: URL, inBlock blockId: String) -> String? {
        items.first { $0.isMarkdownImage(url, inBlock: blockId) }?.id
    }

    private static let codeFence = /(?ms)^[ \t]*(`{3,}|~{3,}).*?^[ \t]*\1[ \t]*$/
    private static let inlineCode = /`[^`\n]*`/
    private static let markdownImage = /!\[[^\]]*\]\(\s*<?([^\s)>]+)>?(?:\s+"[^"]*")?\s*\)/

    static func markdownItems(in block: ContentBlock, messageId: String, workspaceId: String) -> [ImageLightboxItem] {
        guard let text = block.resolvedText, text.contains("![") else { return [] }
        let prose = ContentBlockView.stripSuggestedPrompts(text)
            .replacing(codeFence, with: "")
            .replacing(inlineCode, with: "")
        return prose.matches(of: markdownImage).enumerated().compactMap { index, match in
            guard let url = URL(string: String(match.output.1)), isMarkdownImage(url) else { return nil }
            return ImageLightboxItem(
                id: "\(block.id)#image-\(index)",
                messageId: messageId,
                source: .markdown(url, workspaceId: workspaceId, blockId: block.id)
            )
        }
    }

    private static func isMarkdownImage(_ url: URL) -> Bool {
        switch MarkdownImageRoute.route(for: url) {
        case let .workspaceAsset(link?):
            !WorkspaceVideo.isVideo(path: link.assetId) && !WorkspacePDF.isPDF(path: link.assetId)
        case let .intentFile(link):
            link.isImage
        case .remote:
            true
        case .workspaceAsset(nil), .fallback:
            false
        }
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
    @Entry var markdownImageGalleryBlockID: String?
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
