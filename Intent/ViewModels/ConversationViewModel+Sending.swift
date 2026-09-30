import Foundation
import UIKit

extension ConversationViewModel {
    private enum ComposerImageSelection {
        case explicit([UIImage])
        case pending
    }

    private struct SendComposerState {
        let textRevision: Int
        let imageRevision: Int
        let imageRecovery: ComposerImageRecovery
    }

    func sendMessage(_ content: String) async {
        await sendMessage(content, imageSelection: .pending)
    }

    func sendMessage(_ content: String, images: [UIImage]) async {
        await sendMessage(content, imageSelection: .explicit(images))
    }

    private func sendMessage(_ content: String, imageSelection: ComposerImageSelection) async {
        let sendingStore = store
        let sourceFiles = pendingFiles
        let textRevision = composerTextRevision
        let imageRevision = attachmentPipeline.imageSelectionRevision
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
        let composer = SendComposerState(
            textRevision: textRevision,
            imageRevision: imageRevision,
            imageRecovery: imageRecovery
        )
        let attemptId = sendingStore.beginSendAttempt(
            agentId: agentId,
            content: content,
            workspaceId: workspaceId,
            images: sourceImages,
            files: sourceFiles,
            fileAccess: attachmentPipeline.retainFileAccess(for: sourceFiles)
        )
        guard let attempt = sendingStore.sendAttempts.first(where: { $0.id == attemptId }),
              await prepareSendAttempt(attempt, in: sendingStore, composer: composer) else { return }
        do {
            try await sendingStore.sendPreparedAttempt(attemptId)
            guard store === sendingStore else { return }
            attachmentPipeline.clearPendingFiles(ids: Set(sourceFiles.map(\.id)))
            if case .pending = imageSelection, imageRevision == attachmentPipeline.imageSelectionRevision {
                pendingImages.removeAll()
            }
            if composerTextRevision == textRevision {
                PersistenceManager.shared.clearDraft(workspaceId: workspaceId, agentId: agentId)
            }
            scheduleDebouncedMarkSeen()
        } catch {
            // Retained state owns recovery; raw foreign diagnostics are not UI.
            AppLog.conversation.error("[ConversationViewModel] Message delivery was not confirmed")
        }
    }

    private func prepareSendAttempt(
        _ attempt: ConversationSendAttempt,
        in sendingStore: ConversationStore,
        composer: SendComposerState
    ) async -> Bool {
        let imagePayload: OutgoingImagePayload
        do {
            imagePayload = try await buildImageBlocks(from: attempt.images)
        } catch {
            sendingStore.failSendPreparation(attempt.id)
            guard ownsSendPreparation(attempt.id, in: sendingStore) else { return false }
            attachmentPipeline.surfaceImagePlacementFailure(
                error,
                content: composerTextRevision == composer.textRevision ? attempt.content : "",
                imageRecovery: attachmentPipeline.imageSelectionRevision == composer.imageRevision
                    ? composer.imageRecovery : .preserveCurrentSelection,
                messageText: &messageText
            )
            return false
        }
        guard ownsSendPreparation(attempt.id, in: sendingStore) else { return false }
        sendingStore.prepareSendAttempt(attempt.id, imagePayload: imagePayload, filePayload: .none, complete: false)

        let filePayload: OutgoingFilePayload
        do {
            filePayload = try await buildFileBlocks(from: attempt.files)
        } catch {
            sendingStore.failSendPreparation(attempt.id)
            guard ownsSendPreparation(attempt.id, in: sendingStore) else { return false }
            attachmentPipeline.surfaceFilePlacementFailure(
                error,
                content: composerTextRevision == composer.textRevision ? attempt.content : "",
                imageRecovery: attachmentPipeline.imageSelectionRevision == composer.imageRevision
                    ? composer.imageRecovery : .preserveCurrentSelection,
                messageText: &messageText
            )
            return false
        }
        guard ownsSendPreparation(attempt.id, in: sendingStore) else { return false }
        sendingStore.prepareSendAttempt(attempt.id, imagePayload: imagePayload, filePayload: filePayload)
        return true
    }

    private func ownsSendPreparation(_ messageId: String, in sendingStore: ConversationStore) -> Bool {
        store === sendingStore && sendingStore.sendAttempts.contains { $0.id == messageId }
    }

    var sendRecoveryAttempts: [ConversationSendAttempt] {
        store.sendAttempts.filter { $0.status.needsRecovery }
    }

    func inspectSendAttempt(_ messageId: String) async {
        await store.inspectSendAttempt(messageId)
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
        agentName = AgentSession.displayName(for: newName)
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
