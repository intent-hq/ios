import Foundation
@testable import Intent
import PhotosUI
import SwiftUI
import Testing
import UIKit

extension ConversationViewModelTests {
    @Test(arguments: [false, true])
    func questionAnswersSendImagesWithMetadata(assistant: Bool) async throws {
        let workspaceId = assistant ? Workspace.chiefWorkspaceId : "test-ws"
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: workspaceId)
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let image = try #require(UIImage(systemName: "star"))
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.addImage(image)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try questionAnswerRequest(fake)
        let blocks = try #require(sent["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "image")
        #expect(blocks[0]["mimeType"] as? String == "image/jpeg")
        #expect(sent["fileBlocks"] == nil)
        if workspaceId == Workspace.chiefWorkspaceId {
            #expect(!fake.requestLog.contains { $0.method.hasPrefix("file.") })
            #expect(blocks[0]["attachmentId"] == nil)
            let encoded = try #require(blocks[0]["data"] as? String)
            let data = try #require(Data(base64Encoded: encoded))
            #expect(UIImage(data: data) != nil)
        } else {
            #expect(blocks[0]["attachmentId"] as? String == "att-1")
            #expect(blocks[0]["data"] == nil)
            #expect(fake.paramsForMethod("file.placeAttachment").count == 1)
        }
        #expect(attachments.pendingImages.isEmpty)
        #expect(viewModel.pendingImages.isEmpty)
    }

    @Test(arguments: [false, true])
    func questionAnswersSendFilesWithMetadata(includeImage: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        attachments.addFiles([url])
        if includeImage {
            attachments.addImage(try #require(UIImage(systemName: "star")))
            fake.responseQueueMap["file.placeAttachment"] = [try #require(fake.responseMap["file.placeAttachment"])]
        }
        fake.responseMap["file.placeAttachment"] = questionFilePlacement(url)

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try questionAnswerRequest(fake)
        let blocks = try #require(sent["fileBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "file")
        #expect(blocks[0]["attachmentId"] as? String == "answer-file")
        #expect(blocks[0]["fileName"] as? String == url.lastPathComponent)
        #expect(blocks[0]["mimeType"] as? String == "text/plain")
        #expect(blocks[0]["size"] as? Int == 5)
        #expect((sent["imageBlocks"] != nil) == includeImage)
        let placement = try #require(fake.paramsForMethod("file.placeAttachment").last)
        #expect(placement["workspaceId"] as? String == "test-ws")
        #expect(placement["data"] as? String == Data("hello".utf8).base64EncodedString())
        #expect(!attachments.hasPendingAttachments)
        #expect(!viewModel.attachmentPipeline.hasPendingAttachments)
    }

    @Test(arguments: [false, true])
    func questionUploadFailureRetainsAttachmentsForRetry(file: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        if file {
            attachments.addFiles([url])
            fake.responseMap["file.placeAttachment"] = questionFilePlacement(url)
        } else {
            attachments.addImage(try #require(UIImage(systemName: "star")))
        }
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "Upload", code: 1, userInfo: [NSLocalizedDescriptionKey: "registry full"]
        )

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(fake.paramsForMethod("agent.sendMessage").isEmpty)
        #expect(viewModel.pendingQuestions?.messageId == "a1")
        let error = file ? attachments.filePlacementError : attachments.imagePlacementError
        #expect(error?.contains("registry full") == true)
        #expect((file ? viewModel.filePlacementError : viewModel.imagePlacementError) == error)
        #expect(attachments.hasPendingAttachments)
        #expect(!viewModel.attachmentPipeline.hasPendingAttachments)
        #expect(attachments.fileUploadProgress.isEmpty)
        fake.errorMap["file.placeAttachment"] = nil

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try questionAnswerRequest(fake)
        #expect(sent[file ? "fileBlocks" : "imageBlocks"] != nil)
        #expect(!attachments.hasPendingAttachments)
        #expect(attachments.imagePlacementError == nil)
        #expect(attachments.filePlacementError == nil)
    }

    @Test func questionSendFailureKeepsAttachmentsAndComposerDraft() async throws {
        let (viewModel, fake) = makeFakeBackedVM(sendError: NSError(domain: "WebSocket", code: -32_000))
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        let image = try #require(UIImage(systemName: "star"))
        attachments.addImage(image)
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        attachments.addFiles([url])
        fake.responseQueueMap["file.placeAttachment"] = [try #require(fake.responseMap["file.placeAttachment"])]
        fake.responseMap["file.placeAttachment"] = questionFilePlacement(url)
        viewModel.messageText = "Unrelated composer draft"
        defer { viewModel.messageText = "" }

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        let sent = try questionAnswerRequest(fake)
        #expect(sent["imageBlocks"] != nil)
        #expect(sent["fileBlocks"] != nil)
        #expect(attachments.pendingImages.first === image)
        #expect(attachments.pendingFiles.map(\.url) == [url])
        #expect(viewModel.pendingQuestions?.messageId == "a1")
        #expect(viewModel.messageText == "Unrelated composer draft")
    }

    @Test func questionAttachmentsStayOutOfOrdinarySendsAndOtherQuestionSets() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage(id: "a2")]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        let image = try #require(UIImage(systemName: "star"))
        attachments.addImage(image)
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        attachments.addFiles([url])

        await viewModel.sendMessage("ordinary message")
        #expect(attachments.pendingImages.first === image)
        #expect(attachments.pendingFiles.map(\.url) == [url])
        _ = viewModel.questionAttachments(for: "a2")
        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a2")

        let requests = fake.paramsForMethod("agent.sendMessage")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0["imageBlocks"] == nil && $0["fileBlocks"] == nil })
        #expect(!fake.requestLog.contains { $0.method.hasPrefix("file.") })
        #expect(!attachments.hasPendingAttachments, "superseded question selections are released")
    }

    @Test(arguments: [false, true])
    func questionDismissalClearsAttachmentsOnlyOnSuccess(fails: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.dismissQuestions"] = ["success": true, "dismissedQuestionsMessageId": "a1"]
        if fails { fake.errorMap["agent.dismissQuestions"] = NSError(domain: "WebSocket", code: -32_000) }
        viewModel.store.messages = [questionMessage()]
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.addImage(try #require(UIImage(systemName: "star")))
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        attachments.addFiles([url])

        await viewModel.dismissQuestions(messageId: "a1")

        #expect(attachments.hasPendingAttachments == fails)
        #expect((viewModel.dismissQuestionsError != nil) == fails)
        #expect((viewModel.pendingQuestions != nil) == fails)
    }

    @Test func questionSetReplacementCancelsPendingPhotoImport() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let attachments = viewModel.questionAttachments(for: "a1")
        let photoImport = Task { await suspendUntilCancelled() }
        defer { photoImport.cancel() }
        attachments.photoImportTask = photoImport
        attachments.addImage(try #require(UIImage(systemName: "star")))

        _ = viewModel.questionAttachments(for: "a2")

        #expect(photoImport.isCancelled)
        #expect(!attachments.hasPendingAttachments)
        await photoImport.value
    }

    @Test func assistantQuestionVideoIsRejectedBeforeSend() async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: Workspace.chiefWorkspaceId)
        viewModel.store.messages = [questionMessage()]
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.pendingFiles = [PendingFile(url: URL(fileURLWithPath: "/tmp/answer.mp4"), displayName: "answer.mp4", size: 0)]
        attachments.addImage(try #require(UIImage(systemName: "star")))

        await viewModel.submitQuestionAnswers(try firstAnswer(viewModel), answeredQuestionsMessageId: "a1")

        #expect(fake.requestLog.isEmpty)
        #expect(attachments.filePlacementError?.contains("not in the Assistant") == true)
        #expect(attachments.pendingImages.count == 1)
        #expect(attachments.pendingFiles.count == 1)
        #expect(viewModel.pendingQuestions?.messageId == "a1")
    }

    @Test func questionFileFailureAfterImageUploadDoesNotSendPartialAnswer() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.addImage(try #require(UIImage(systemName: "star")))
        let url = try questionAttachmentFile()
        defer { try? FileManager.default.removeItem(at: url) }
        attachments.addFiles([url])
        fake.pendingMethods = ["file.placeAttachment"]
        let submission = Task { await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1") }
        defer { submission.cancel() }
        try await fake.waitForPendingRequests("file.placeAttachment")
        fake.resolvePending("file.placeAttachment", with: [
            "attachmentId": "image-uploaded", "fileName": "image.jpg", "path": "image.jpg", "size": 1
        ])
        try await fake.waitForPendingRequests("file.placeAttachment")
        fake.failPending("file.placeAttachment", with: NSError(domain: "Upload", code: 1))
        await submission.value

        #expect(fake.paramsForMethod("agent.sendMessage").isEmpty)
        #expect(attachments.pendingImages.count == 1)
        #expect(attachments.pendingFiles.map(\.url) == [url])
        #expect(attachments.filePlacementError != nil)
        #expect(viewModel.pendingQuestions?.messageId == "a1")
    }

    @Test func questionAnswerClearsAttachmentsOnlyAfterAcceptance() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.addImage(try #require(UIImage(systemName: "star")))
        fake.pendingMethods = ["agent.sendMessage"]
        let submission = Task { await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1") }
        defer { submission.cancel() }
        try await fake.waitForPendingRequests("agent.sendMessage")
        #expect(attachments.pendingImages.count == 1)
        #expect(viewModel.submittingQuestionMessageIds.contains("a1"))

        await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1")

        #expect(fake.paramsForMethod("agent.sendMessage").count == 1, "duplicate taps cannot resend while uploading/sending")
        fake.resolvePending("agent.sendMessage", with: ["success": true, "queued": false])
        await submission.value
        #expect(!attachments.hasPendingAttachments)
        #expect(viewModel.submittingQuestionMessageIds.isEmpty)
    }

    @Test(arguments: ["cleared", "dismissed", "answered", "queued", "replaced", "removed", "streaming", "untagged"])
    func questionSubmissionRechecksRetirementAfterUpload(change: String) async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.store.messages = [questionMessage()]
        viewModel.store.pendingQuestionsMessageId = "a1"
        let answers = try firstAnswer(viewModel)
        let attachments = viewModel.questionAttachments(for: "a1")
        attachments.addImage(try #require(UIImage(systemName: "star")))
        fake.pendingMethods = ["file.placeAttachment"]
        let submission = Task { await viewModel.submitQuestionAnswers(answers, answeredQuestionsMessageId: "a1") }
        defer { submission.cancel() }
        try await fake.waitForPendingRequests("file.placeAttachment")
        let metadata = ["type": AnyCodable("question_answers"), "answeredQuestionsMessageId": AnyCodable("a1")]
        switch change {
        case "cleared": viewModel.store.pendingQuestionsMessageId = ""
        case "dismissed": viewModel.store.dismissedQuestionsMessageId = "a1"
        case "answered":
            var answer = textMessage(role: .user, text: "Answered elsewhere")
            answer.metadata = metadata
            viewModel.store.messages.append(answer)
        case "queued": viewModel.store.queuedMessages = [queuedEntry(id: "remote-answer", metadata: metadata)]
        case "replaced": viewModel.store.pendingQuestionsMessageId = "a2"
        case "removed": viewModel.store.pendingQuestionsMessageId = nil
        case "streaming": viewModel.store.isStreaming = true
        default: viewModel.store.messages.append(textMessage(role: .user, text: "Unrelated follow-up"))
        }
        let messageIdsBeforeUploadCompletes = viewModel.messages.map(\.id)
        fake.resolvePending("file.placeAttachment", with: try #require(fake.responseMap["file.placeAttachment"]))
        await submission.value

        let retired = change != "streaming" && change != "untagged"
        #expect(fake.paramsForMethod("agent.sendMessage").count == (retired ? 0 : 1))
        if retired { #expect(viewModel.messages.map(\.id) == messageIdsBeforeUploadCompletes) }
        #expect(viewModel.submittingQuestionMessageIds.isEmpty)
        #expect(!attachments.hasPendingAttachments)
        #expect(viewModel.questionAttachmentPipelines["a1"] == nil)
    }

    @Test func questionPhotoImportsCountPendingImagesAcrossBatches() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let attachments = viewModel.questionAttachments(for: "a1")
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        let data = try #require(image.pngData())
        var loadedPhotos = 0
        attachments.loadPhotoData = { _ in
            loadedPhotos += 1
            return data
        }
        attachments.addImage(image)
        #expect(attachments.remainingPhotoImageCount == limit - 1)
        attachments.selectedPhotoItems = (1..<limit).map { PhotosPickerItem(itemIdentifier: "batch-\($0)") }
        attachments.startLoadingSelectedPhotos(workspaceId: "test-ws")
        await attachments.photoImportTask?.value
        #expect(attachments.pendingImages.count == limit)
        #expect(attachments.remainingPhotoImageCount == 0)
        #expect(attachments.selectedPhotoItems.isEmpty)

        attachments.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "over-cap")]
        attachments.startLoadingSelectedPhotos(workspaceId: "test-ws")
        await attachments.photoImportTask?.value
        #expect(attachments.pendingImages.count == limit)
        #expect(loadedPhotos == limit - 1, "over-cap selections are rejected before loading")
        #expect(attachments.imagePlacementError?.contains("up to \(limit) images") == true)

        attachments.removeImage(at: 0)
        #expect(attachments.remainingPhotoImageCount == 1)
        attachments.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "replacement")]
        attachments.startLoadingSelectedPhotos(workspaceId: "test-ws")
        await attachments.photoImportTask?.value
        #expect(attachments.pendingImages.count == limit)
        #expect(loadedPhotos == limit)
        #expect(attachments.imagePlacementError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func questionPhotoImportRechecksCapacityAfterLoading() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let attachments = viewModel.questionAttachments(for: "a1")
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        let data = try #require(image.pngData())
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        defer { didStart.finish(); release.finish() }
        attachments.loadPhotoData = { _ in
            didStart.yield()
            for await _ in gate { break }
            return data
        }
        attachments.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "in-flight")]
        attachments.startLoadingSelectedPhotos(workspaceId: "test-ws")
        let importTask = try #require(attachments.photoImportTask)
        defer { importTask.cancel() }
        for await _ in started { break }
        for _ in 0..<limit { attachments.addImage(image) }
        release.yield()
        await importTask.value

        #expect(attachments.pendingImages.count == limit)
        #expect(attachments.pendingImages.allSatisfy { $0 === image }, "the late import must not replace existing images")
        #expect(attachments.imagePlacementError?.contains("up to \(limit) images") == true)
    }

    private func questionAnswerRequest(_ fake: FakeConnectionManager) throws -> [String: Any] {
        let requests = fake.paramsForMethod("agent.sendMessage")
        #expect(requests.count == 1)
        let sent = try #require(requests.first)
        #expect(sent["content"] as? String == "Q: Which auth method?\nA: OAuth")
        let metadata = try #require(sent["messageMetadata"] as? [String: Any])
        #expect(metadata["type"] as? String == "question_answers")
        #expect(metadata["answeredQuestionsMessageId"] as? String == "a1")
        return sent
    }

    private func questionAttachmentFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("question-\(UUID()).txt")
        try Data("hello".utf8).write(to: url)
        return url
    }

    private func questionFilePlacement(_ url: URL) -> [String: Any] {
        let byteCount = 5
        return [
            "attachmentId": "answer-file", "fileName": url.lastPathComponent,
            "path": ".intent/attachments/answer-file/\(url.lastPathComponent)", "size": byteCount, "mimeType": "text/plain"
        ]
    }
}
