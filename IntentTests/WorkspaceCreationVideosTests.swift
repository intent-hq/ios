import Foundation
@testable import Intent
import Testing
import UIKit

@MainActor
struct WorkspaceCreationVideosTests {
    @Test func videoOnlyDraftResumesAndRemovalReleasesOwnedFile() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var draft = WorkspaceCreationDraft(backendID: nil, persistence: .ephemeral())
        draft.navigationPath = [.branches, .create]
        let operation = try #require(draft.images.addMedia([{ .video(try await ImportedPhotoVideo.importFile(at: source)) }]))
        #expect(draft.images.isImporting)
        await operation.value
        #expect(!draft.images.isImporting)
        let id = try #require(draft.images.videos.first?.id)
        let url = try #require(draft.images.videos.first?.url)
        #expect(url != source)
        #expect(draft.images.videos.first?.video?.poster != nil)
        #expect(draft.images.images.isEmpty, "Videos must never become inline image blocks")
        let restored = try #require(draft.resumable)
        #expect(restored.images.videos.first?.id == id)
        draft.images.remove(id)
        #expect(draft.resumable == nil)
        try await waitUntil("removed draft video cleanup") { !FileManager.default.fileExists(atPath: url.path) }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func imagesAndVideosShareSelectionLimitAndFailedImportPreservesDraft() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let video = try await ImportedPhotoVideo.importFile(at: source)
        let imageData = try #require(video.poster?.pngData())
        var draft = WorkspaceCreationDraft(backendID: nil, persistence: .ephemeral())
        draft.messageText = "Keep the prompt"
        await draft.images.addMedia([{ .video(video) }, { .image(imageData) }])?.value
        let ids = draft.images.videos.map(\.id)
        await draft.images.addMedia([{ throw ImportedPhotoVideo.ImportError.tooLarge }])?.value
        #expect(draft.images.videos.map(\.id) == ids)
        #expect(draft.messageText == "Keep the prompt")
        #expect(draft.images.errorMessage?.contains("max 200 MB") == true)
        #expect(!draft.images.isImporting)
        await draft.images.addMedia([{ .video(video) }, { .video(video) }, { .image(imageData) }])?.value
        #expect(draft.images.remainingCount == 0)
        #expect(draft.images.addMedia([{ .video(video) }]) == nil)
        #expect(draft.images.errorMessage?.contains("Remove") == true)
        draft.images.remove(try #require(ids.first))
        #expect(draft.images.remainingCount == 1)
    }

    @Test func cancelledVideoBatchCannotPublishIntoNewerDraftImport() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let video = try await ImportedPhotoVideo.importFile(at: source)
        let images = WorkspaceCreationImages()
        var continuation: CheckedContinuation<WorkspaceCreationImages.Media, Never>?
        let old = try #require(images.addMedia([{ await withCheckedContinuation { continuation = $0 } }]))
        try await waitUntil("suspended draft import") { continuation != nil }
        images.cancelImport()
        let fresh = try #require(images.addMedia([{ .video(video) }]))
        continuation?.resume(returning: .video(video))
        await old.value
        await fresh.value
        #expect(images.videos.count == 1)
        #expect(!images.isImporting)
        #expect(images.errorMessage == nil)
    }

    @Test(arguments: [false, true])
    func firstMessageWaitsForVideoPlacementAndKeepsImages(largeVideo: Bool) async throws {
        let source = try await videoSource(largeVideo: largeVideo)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fake = makeConnection()
        let file = try await pendingVideo(source)
        let submission = try WorkspaceCreationVideoSubmission(connection: fake, params: params(), videos: [file])
        let method = "file.attachmentUpload.chunk"
        fake.pendingMethods.insert(method)
        let task = Task { try await submission.submit() }
        defer { task.cancel() }
        try await fake.waitForPendingRequests(method)
        #expect(submission.isUploading)
        #expect(submission.isSubmitting)
        #expect(submission.uploadProgress == 0)
        #expect(!fake.didCallMethod("agent.sendMessage"))
        let create = try #require(fake.paramsForMethod("workspace.create").first)
        let agent = try #require(create["initialAgent"] as? [String: Any])
        #expect(agent["prompt"] == nil)
        #expect(agent["imageBlocks"] == nil)
        #expect(agent["fileBlocks"] == nil)
        #expect(agent["provider"] as? String == "codex")
        #expect(agent["model"] as? String == "chosen-model")
        #expect(agent["specialist"] as? String == "verifier")
        #expect(agent["reasoningEffort"] as? String == "high")
        #expect(create["idempotencyKey"] as? String == "creation-key")
        fake.pendingMethods.remove(method)
        fake.resolvePending(method, with: [:])
        #expect(try await task.value.id == "new-workspace")
        let send = try #require(fake.paramsForMethod("agent.sendMessage").first)
        #expect(send["content"] as? String == "Review this recording")
        #expect(send["workspaceId"] as? String == "new-workspace")
        #expect(send["agentId"] as? String == "new-agent")
        let videos = try #require(send["fileBlocks"] as? [[String: Any]])
        #expect(videos.count == 1)
        #expect(videos[0]["attachmentId"] as? String == "video-1")
        #expect(videos[0]["mimeType"] as? String == "video/mp4")
        #expect(videos[0]["data"] == nil)
        let images = try #require(send["imageBlocks"] as? [[String: Any]])
        #expect(images[0]["data"] as? String == "aW1hZ2U=")
        #expect(fake.didCallMethod("file.attachmentUpload.begin"))
        #expect(fake.didCallMethod("file.attachmentUpload.commit"))
        #expect(!fake.didCallMethod("file.placeAttachment"), "Even small Photos videos must stream from disk")
        #expect(!submission.isSubmitting)
        #expect(!submission.isUploading)
    }

    @Test func failedSecondUploadResumesSameWorkspaceWithoutResendingFirstVideo() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var draft = WorkspaceCreationDraft(backendID: nil, persistence: .ephemeral())
        draft.navigationPath = [.branches, .create]
        draft.messageText = "Review this recording"
        await draft.images.addMedia([
            { .video(try await ImportedPhotoVideo.importFile(at: source)) },
            { .video(try await ImportedPhotoVideo.importFile(at: source)) }
        ])?.value
        let fake = makeConnection()
        fake.pendingMethods.insert("file.attachmentUpload.chunk")
        let submission = try WorkspaceCreationVideoSubmission(connection: fake, params: params(), videos: draft.images.videos)
        draft.videoSubmission = submission
        let task = Task { try await submission.submit() }
        defer { task.cancel() }
        try await fake.waitForPendingRequests("file.attachmentUpload.chunk")
        fake.resolvePending("file.attachmentUpload.chunk", with: [:])
        try await fake.waitForPendingRequests("file.attachmentUpload.chunk")
        #expect(submission.uploadProgress == 0.5)
        fake.failPending("file.attachmentUpload.chunk", with: URLError(.networkConnectionLost))
        do {
            _ = try await task.value
            Issue.record("The failed upload should keep the form open")
        } catch {
            #expect(error.localizedDescription.contains("prompt and attachments are saved"))
        }
        #expect(!fake.didCallMethod("agent.sendMessage"))
        #expect(draft.messageText == "Review this recording")
        #expect(draft.images.videos.count == 2)
        let resumed = try #require(draft.resumable?.videoSubmission)
        fake.pendingMethods.remove("file.attachmentUpload.chunk")
        fake.responseMap["file.attachmentUpload.commit"] = placement(id: "video-2")
        #expect(try await resumed.submit().id == "new-workspace")
        #expect(fake.paramsForMethod("workspace.create").count == 1)
        #expect(fake.paramsForMethod("file.attachmentUpload.begin").count == 3)
        #expect(fake.paramsForMethod("file.attachmentUpload.commit").count == 2)
        let send = try #require(fake.paramsForMethod("agent.sendMessage").first)
        let files = try #require(send["fileBlocks"] as? [[String: Any]])
        #expect(files.compactMap { $0["attachmentId"] as? String } == ["video-1", "video-2"])
    }

    @Test func lostCreationReplyReusesKeyAndNeverStartsAgentEarly() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fake = makeConnection()
        fake.errorQueueMap["workspace.create"] = [URLError(.timedOut)]
        let submission = try WorkspaceCreationVideoSubmission(connection: fake, params: params(), videos: [try await pendingVideo(source)])
        await #expect(throws: URLError.self) { _ = try await submission.submit() }
        #expect(!fake.didCallMethod("file.attachmentUpload.begin"))
        #expect(!fake.didCallMethod("agent.sendMessage"))
        _ = try await submission.submit()
        let requests = fake.paramsForMethod("workspace.create")
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0["idempotencyKey"] as? String == "creation-key" })
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    @Test func unconfirmedFirstMessageOnlyChecksStatusAndDoesNotSendTwice() async throws {
        let source = try await videoSource()
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fake = makeConnection()
        fake.errorMap["agent.sendMessage"] = URLError(.timedOut)
        let submission = try WorkspaceCreationVideoSubmission(connection: fake, params: params(), videos: [try await pendingVideo(source)])
        await #expect(throws: WorkspaceCreationVideoSubmission.SubmissionError.unconfirmed) { _ = try await submission.submit() }
        #expect(submission.needsStatusCheck)
        fake.responseMap["agent.getConversation"] = ["messages": []]
        await #expect(throws: WorkspaceCreationVideoSubmission.SubmissionError.unconfirmed) { _ = try await submission.submit() }
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
        #expect(fake.paramsForMethod("workspace.create").count == 1)
        #expect(fake.paramsForMethod("file.attachmentUpload.commit").count == 1)
        let message = try #require(fake.paramsForMethod("agent.sendMessage").first?["messageId"] as? String)
        let echoed: [String: Any] = [
            "id": message, "role": "user",
            "contentBlocks": [["type": "text", "text": "Review this recording"]],
            "timestamp": "2026-10-06T12:00:00Z"
        ]
        fake.responseMap["agent.getConversation"] = ["messages": [echoed]]
        #expect(try await submission.submit().id == "new-workspace")
        #expect(!submission.needsStatusCheck)
        #expect(fake.paramsForMethod("agent.sendMessage").count == 1)
    }

    private func videoSource(largeVideo: Bool = false) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("creation-video-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent("recording.mp4")
        try await IntentFileVideoTests.videoBytes().write(to: url)
        if largeVideo {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(AttachmentUploadService.maxSingleShotBytes + 1))
            try handle.close()
        }
        return url
    }

    private func pendingVideo(_ source: URL) async throws -> PendingFile {
        let video = try await ImportedPhotoVideo.importFile(at: source)
        return PendingFile(url: video.url, displayName: "recording.mp4", size: Int64(video.size), video: video)
    }

    private func params() -> [String: Any] {
        CreateWorkspaceView.buildCreateWorkspaceParams(
            githubUrl: "https://github.com/example/project",
            baseRef: "main",
            idempotencyKey: "creation-key",
            initialAgent: .init(
                specialist: SpecialistInfo(id: "verifier", name: "Verifier", description: "Reviews"),
                provider: ProviderInfo(id: "codex", authenticated: .signedIn),
                model: ModelInfo(id: "chosen-model", name: "Chosen model", provider: "codex"),
                message: "Review this recording",
                reasoningEffort: "high",
                imageBlocks: [["type": "image", "mimeType": "image/jpeg", "data": "aW1hZ2U="]]
            )
        )
    }

    private func makeConnection() -> FakeConnectionManager {
        let fake = FakeConnectionManager()
        fake.responseMap["workspace.create"] = [
            "workspace": ["id": "new-workspace", "title": "New workspace"], "initialAgent": ["id": "new-agent"]
        ]
        fake.responseMap["file.attachmentUpload.begin"] = ["uploadId": "upload-1", "maxChunkBytes": AttachmentUploadService.uploadChunkBytes]
        fake.responseMap["file.attachmentUpload.chunk"] = [:]
        fake.responseMap["file.attachmentUpload.commit"] = placement()
        fake.responseMap["file.attachmentUpload.abort"] = [:]
        fake.responseMap["agent.sendMessage"] = ["success": true, "queued": false]
        return fake
    }

    private func placement(id: String = "video-1") -> [String: Any] {
        [
            "attachmentId": id, "fileName": "recording.mp4", "mimeType": "video/mp4", "size": 42,
            "path": ".intent/attachments/\(id)/recording.mp4"
        ]
    }
}
