import Foundation
@testable import Intent
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    @Test(arguments: [false, true])
    func sendFailureAfterPlacementRetainsImagesAndNewerDraft(assistant: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: assistant ? Workspace.chiefWorkspaceId : "test-ws")
        fake.pendingMethods.insert("agent.sendMessage")
        let image = try #require(UIImage(systemName: "star"))
        let nextImage = try #require(UIImage(systemName: "circle"))
        let file = PendingFile(url: URL(fileURLWithPath: "/tmp/retained.txt"), displayName: "retained.txt", size: 0)
        // A file added during the send belongs to the newer composer draft.
        let send = Task { await viewModel.sendMessage("original", images: [image]) }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        viewModel.messageText = "new draft"
        viewModel.pendingImages = [nextImage]
        viewModel.pendingFiles = [file]
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -32_603))
        await send.value
        let attempt = try #require(viewModel.sendRecoveryAttempts.first)
        #expect(attempt.content == "original")
        #expect(attempt.images.first === image)
        #expect(attempt.status == .unconfirmed)
        var payload: [String: Any] = [:]
        attempt.imagePayload.apply(to: &payload)
        let block = try #require((payload["imageBlocks"] as? [[String: Any]])?.first)
        if assistant {
            #expect(block["data"] as? String == image.jpegData(compressionQuality: Constants.Conversation.Composer.imageCompressionQuality)?.base64EncodedString())
            #expect(!fake.didCallMethod("file.placeAttachment"))
        } else {
            #expect(block["attachmentId"] as? String == "att-1")
        }
        #expect(viewModel.messageText == "new draft")
        #expect(viewModel.pendingImages.first === nextImage)
        #expect(viewModel.pendingFiles == [file])
        #expect(!attempt.canRetry)
        await #expect(throws: ConversationSendError.replayUnavailable) {
            try await viewModel.store.sendPreparedAttempt(attempt.id)
        }
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func placementFailureKeepsCapturedInputWhenNewSelectionPreventsRestoration() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.pendingMethods.insert("file.placeAttachment")
        let original = try #require(UIImage(systemName: "star"))
        let newer = try #require(UIImage(systemName: "circle"))
        let send = Task { await viewModel.sendMessage("original", images: [original]) }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("file.placeAttachment")
        viewModel.messageText = "new typing"
        viewModel.pendingImages = [newer]
        fake.failPending("file.placeAttachment", with: NSError(domain: "WebSocket", code: -2))
        await send.value
        let attempt = try #require(viewModel.sendRecoveryAttempts.first)
        #expect(attempt.status == .notSent)
        #expect(attempt.images.first === original)
        #expect(attempt.content == "original")
        #expect(viewModel.messageText == "new typing")
        #expect(viewModel.pendingImages.first === newer)
        #expect(!fake.didCallMethod("agent.sendMessage"))
    }

    @Test func olderSendSuccessDoesNotClearNewerTypingOrFileSelection() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.pendingMethods.insert("agent.sendMessage")
        viewModel.messageText = ""
        let send = Task { await viewModel.sendMessage("original") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        viewModel.messageText = "new draft"
        let file = PendingFile(url: URL(fileURLWithPath: "/tmp/new.txt"), displayName: "new.txt", size: 0)
        viewModel.pendingFiles = [file]
        PersistenceManager.shared.saveDraft("new draft", workspaceId: viewModel.workspaceId, agentId: viewModel.agentId)
        defer { PersistenceManager.shared.clearDraft(workspaceId: viewModel.workspaceId, agentId: viewModel.agentId) }
        fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false])
        await send.value
        #expect(viewModel.messageText == "new draft")
        #expect(viewModel.pendingFiles == [file])
        #expect(PersistenceManager.shared.loadDraft(workspaceId: viewModel.workspaceId, agentId: viewModel.agentId) == "new draft")
    }

    @Test func imageOnlyFailureSurvivesTranscriptReplacement() async throws {
        let (viewModel, fake) = makeFakeBackedVM(sendError: NSError(domain: "WebSocket", code: -2))
        let image = try #require(UIImage(systemName: "star"))
        await viewModel.sendMessage("", images: [image])
        fake.stubChatSnapshot(messages: [["id": "remote", "role": "assistant", "contentBlocks": []]])
        await viewModel.store.subscribeLiveChat(agentId: viewModel.agentId, workspaceId: viewModel.workspaceId)
        let attempt = try #require(viewModel.sendRecoveryAttempts.first)
        #expect(attempt.content.isEmpty)
        #expect(attempt.images.first === image)
        #expect(attempt.status == .unconfirmed)
        #expect(viewModel.messages.map(\.id) == ["remote"])
    }

    @Test func failedSuggestedPromptRetainsAttemptWithoutTouchingComposer() async throws {
        let (viewModel, _) = makeFakeBackedVM(sendError: NSError(domain: "WebSocket", code: -32_603))
        viewModel.messageText = "my draft"
        let image = try #require(UIImage(systemName: "star"))
        viewModel.pendingImages = [image]
        await viewModel.sendSuggestedPrompt("suggestion")
        #expect(viewModel.messageText == "my draft")
        #expect(viewModel.pendingImages.first === image)
        #expect(viewModel.sendRecoveryAttempts.first?.content == "suggestion")
        #expect(viewModel.sendRecoveryAttempts.first?.images.isEmpty == true)
    }

    @Test func fileOnlyFailureRetainsPlacedReferenceAfterComposerSelectionChanges() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.pendingMethods = ["file.placeAttachment", "agent.sendMessage"]
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".txt")
        try Data("original file".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        viewModel.addFiles([url])
        let selectedFile = try #require(viewModel.pendingFiles.first)
        let send = Task { await viewModel.sendMessage("") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests("file.placeAttachment")
        viewModel.clearPendingFiles()
        let newer = PendingFile(url: url, displayName: "new selection", size: 0)
        viewModel.pendingFiles = [newer]
        fake.resolvePending("file.placeAttachment", with: [
            "attachmentId": "original-file", "fileName": "original.txt", "size": 13,
            "path": ".intent/attachments/original-file/original.txt", "mimeType": "text/plain"
        ])
        try await fake.waitForPendingRequests("agent.sendMessage")
        fake.failPending("agent.sendMessage", with: NSError(domain: "WebSocket", code: -2))
        await send.value
        let attempt = try #require(viewModel.sendRecoveryAttempts.first)
        #expect(attempt.files == [selectedFile])
        #expect(attempt.content.isEmpty)
        var params: [String: Any] = [:]
        attempt.filePayload.apply(to: &params)
        #expect((params["fileBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "original-file")
        #expect(viewModel.pendingFiles == [newer])
    }

    @Test func retainedFileAccessOutlivesComposerSelectionUntilRecoveryReset() {
        let stopped = Mutex<[URL]>([])
        let pipeline = ConversationAttachmentPipeline(
            startSecurityScopedAccess: { _ in true },
            stopSecurityScopedAccess: { url in stopped.withLock { $0.append(url) } }
        )
        let url = URL(fileURLWithPath: "/tmp/retained-access.txt")
        pipeline.addFiles([url])
        let store = ConversationStore(connectionManager: FakeConnectionManager())
        let id = store.beginSendAttempt(
            agentId: "a",
            content: "",
            workspaceId: "w",
            files: pipeline.pendingFiles,
            fileAccess: pipeline.retainFileAccess(for: pipeline.pendingFiles)
        )
        store.failSendPreparation(id)
        pipeline.clearPendingFiles()
        #expect(stopped.withLock { $0 } == [url], "only the composer's lease ends")
        store.reset()
        #expect(stopped.withLock { $0 } == [url, url], "the attempt's extra lease is balanced")
    }

    @Test(arguments: [false, true])
    func cancellationBeforeDispatchRetainsPreparedSendAndCancelledRetry(retryEntry: Bool) async throws {
        let stopped = Mutex<[URL]>([])
        let pipeline = ConversationAttachmentPipeline(
            startSecurityScopedAccess: { _ in true },
            stopSecurityScopedAccess: { url in stopped.withLock { $0.append(url) } }
        )
        let url = URL(fileURLWithPath: "/tmp/cancelled-send.txt")
        pipeline.addFiles([url])
        let files = pipeline.pendingFiles
        let image = try #require(UIImage(systemName: "star"))
        let fake = FakeConnectionManager()
        let store = ConversationStore(connectionManager: fake)
        let id = store.beginSendAttempt(
            agentId: "a",
            content: "original",
            workspaceId: "w",
            images: [image],
            files: files,
            fileAccess: pipeline.retainFileAccess(for: files),
            messageMetadata: .fields(["selection": "original"])
        )
        store.prepareSendAttempt(id, imagePayload: .attachments([["type": "image", "attachmentId": "image-1"]]), filePayload: .attachments([["type": "file", "attachmentId": "file-1"]]))
        pipeline.clearPendingFiles()
        #expect(store.sendAttempts.first?.status == .preparing)
        for _ in 0 ..< (retryEntry ? 2 : 1) {
            let send = Task { @MainActor in try await store.sendPreparedAttempt(id) }
            // No suspension on MainActor before cancel: the request cannot have entered yet.
            send.cancel()
            await #expect(throws: CancellationError.self) { try await send.value }
            #expect(store.sendAttempts.first?.status == .notSent)
            #expect(store.sendAttempts.first?.canRetry == true)
        }
        #expect(fake.paramsForMethod("agent.sendMessage").isEmpty)
        #expect(store.messages.isEmpty)
        #expect(!store.isStreaming)
        #expect(store.sendAttempts.count == 1)
        #expect(store.sendAttempts.first?.id == id)
        #expect(store.sendAttempts.first?.content == "original")
        #expect(store.sendAttempts.first?.images.first === image)
        #expect(store.sendAttempts.first?.files == files)
        #expect(store.sendAttempts.first?.fileAccess != nil)
        var params: [String: Any] = [:]
        store.sendAttempts[0].imagePayload.apply(to: &params)
        store.sendAttempts[0].filePayload.apply(to: &params)
        store.sendAttempts[0].messageMetadata.apply(to: &params)
        #expect((params["imageBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "image-1")
        #expect((params["fileBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "file-1")
        #expect((params["messageMetadata"] as? [String: Any])?["selection"] as? String == "original")
        #expect(stopped.withLock { $0 } == [url], "cancellation does not release the retained attempt lease")
        store.reset()
        #expect(stopped.withLock { $0 } == [url, url])
    }
}
