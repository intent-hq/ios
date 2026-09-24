import Foundation
@testable import Intent
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    @Test func sendFailureAfterPlacementRetainsImagesAndNewerDraft() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
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
        #expect((payload["imageBlocks"] as? [[String: Any]])?.first?["attachmentId"] as? String == "att-1")
        #expect(viewModel.messageText == "new draft")
        #expect(viewModel.pendingImages.first === nextImage)
        #expect(viewModel.pendingFiles == [file])
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
}
