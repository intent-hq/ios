import Foundation
import UIKit

extension ConversationViewModel {
    private enum ComposerImageSelection {
        case explicit([UIImage])
        case pending
    }

    func sendMessage(_ content: String) async {
        await sendMessage(content, imageSelection: .pending)
    }

    func sendMessage(_ content: String, images: [UIImage]) async {
        await sendMessage(content, imageSelection: .explicit(images))
    }

    private func sendMessage(_ content: String, imageSelection: ComposerImageSelection) async {
        let sourceImages: [UIImage]
        let imageRecovery: ComposerImageRecovery
        switch imageSelection {
        case let .explicit(images):
            sourceImages = images
            imageRecovery = .restore(images)
        case .pending:
            sourceImages = pendingImages
            imageRecovery = .preserveCurrentSelection
        }

        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await buildImageBlocks(from: sourceImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            attachmentPipeline.surfaceImagePlacementFailure(
                error,
                content: content,
                imageRecovery: imageRecovery,
                messageText: &messageText
            )
            return
        }

        let filePayload: OutgoingFilePayload
        do {
            filePayload = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            attachmentPipeline.surfaceFilePlacementFailure(
                error,
                content: content,
                imageRecovery: imageRecovery,
                messageText: &messageText
            )
            return
        }

        do {
            try await store.sendMessage(
                agentId: agentId,
                content: content,
                workspaceId: workspaceId,
                imagePayload: imagePayload,
                filePayload: filePayload
            )
            clearPendingFiles()
            PersistenceManager.shared.clearDraft(workspaceId: workspaceId, agentId: agentId)
            scheduleDebouncedMarkSeen()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Send failed: \(error)")
        }
    }

    func queueMessage(_ content: String) async {
        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await buildImageBlocks(from: pendingImages)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Image placement failed: \(error)")
            attachmentPipeline.surfaceImagePlacementFailure(
                error,
                content: content,
                imageRecovery: .preserveCurrentSelection,
                messageText: &messageText
            )
            return
        }

        let filePayload: OutgoingFilePayload
        do {
            filePayload = try await buildFileBlocks(from: pendingFiles)
        } catch {
            AppLog.conversation.error("[ConversationViewModel] File placement failed: \(error)")
            attachmentPipeline.surfaceFilePlacementFailure(
                error,
                content: content,
                imageRecovery: .preserveCurrentSelection,
                messageText: &messageText
            )
            return
        }

        do {
            try await store.queueMessage(
                agentId: agentId,
                content: content,
                imagePayload: imagePayload,
                filePayload: filePayload
            )
            pendingImages.removeAll()
            clearPendingFiles()
        } catch {
            AppLog.conversation.error("[ConversationViewModel] Queue failed: \(error)")
        }
    }

    func renameAgent(_ newName: String) async throws {
        _ = try await connection.request(
            "agent.rename",
            params: [
                "agentId": agentId,
                "name": newName,
                "workspaceId": workspaceId
            ]
        )
        agentName = newName
    }

    // MARK: - Attachments

    func addImage(_ image: UIImage) { attachmentPipeline.addImage(image) }
    func removeImage(at index: Int) { attachmentPipeline.removeImage(at: index) }
    func loadSelectedPhotos() async { await attachmentPipeline.loadSelectedPhotos() }

    var hasPendingAttachments: Bool { attachmentPipeline.hasPendingAttachments }

    func addFiles(_ urls: [URL]) { attachmentPipeline.addFiles(urls) }
    func removePendingFile(at index: Int) { attachmentPipeline.removePendingFile(at: index) }
    func clearPendingFiles() { attachmentPipeline.clearPendingFiles() }

    var isUploadingFiles: Bool { attachmentPipeline.isUploadingFiles }

    func buildImageBlocks(from images: [UIImage]) async throws -> OutgoingImagePayload {
        try await attachmentPipeline.buildImageBlocks(from: images, workspaceId: workspaceId)
    }

    func buildFileBlocks(from files: [PendingFile]) async throws -> OutgoingFilePayload {
        try await attachmentPipeline.buildFileBlocks(from: files, workspaceId: workspaceId)
    }
}
