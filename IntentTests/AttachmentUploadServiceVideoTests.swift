import Foundation
@testable import Intent
import Testing

extension AttachmentUploadServiceTests {
    @Test(arguments: [("recording.MOV", "video/quicktime"), ("screen.mp4", "video/mp4")])
    func photoVideoUploadsAsFileWithDetectedMIME(_ fixture: (String, String)) async throws {
        let source = try await photoVideoSource(name: fixture.0)
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let originalBytes = try Data(contentsOf: source)
        let fake = FakeConnectionManager()
        fake.responseMap["file.attachmentUpload.begin"] = [
            "uploadId": "upload-1", "maxChunkBytes": AttachmentUploadService.uploadChunkBytes
        ]
        fake.responseMap["file.attachmentUpload.chunk"] = [:]
        fake.responseMap["file.attachmentUpload.commit"] = [
            "attachmentId": "video-1", "fileName": fixture.0, "size": originalBytes.count,
            "path": ".intent/attachments/video-1/\(fixture.0)"
        ]
        let pipeline = ConversationAttachmentPipeline(uploadService: AttachmentUploadService(connection: fake))
        try pipeline.addVideo(try await ImportedPhotoVideo.importFile(at: source), workspaceId: "ws")
        let importedURL = try #require(pipeline.pendingFiles.first?.url)
        #expect(importedURL != source)
        #expect(pipeline.pendingFiles.first?.video?.poster != nil)
        #expect(pipeline.pendingFiles.first?.size == Int64(originalBytes.count))
        try FileManager.default.removeItem(at: source)

        let payload = try await pipeline.buildFileBlocks(from: pipeline.pendingFiles, workspaceId: "ws")
        var params: [String: Any] = [:]
        payload.apply(to: &params)
        let blocks = try #require(params["fileBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "file")
        #expect(blocks[0]["mimeType"] as? String == fixture.1, "older placement responses may omit MIME")
        #expect(blocks[0]["attachmentId"] as? String == "video-1")
        let upload = try #require(fake.paramsForMethod("file.attachmentUpload.begin").first)
        #expect(upload["mimeType"] as? String == fixture.1)
        let chunks = fake.paramsForMethod("file.attachmentUpload.chunk")
        let uploadedBytes = chunks.reduce(into: Data()) { bytes, chunk in
            if let encoded = chunk["data"] as? String, let data = Data(base64Encoded: encoded) { bytes.append(data) }
        }
        #expect(uploadedBytes == originalBytes)
        #expect(FileManager.default.fileExists(atPath: importedURL.path), "placement alone is not delivery")
        pipeline.clearPendingFiles()
        try await waitUntil("imported video cleanup after clearing") {
            !FileManager.default.fileExists(atPath: importedURL.path)
        }
    }

    @Test func photoVideoImportRejectsOversizeBeforeCopying() async throws {
        let source = try await photoVideoSource(name: "huge.mov")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let oversized = ImportedPhotoVideo.maxBytes + 1
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(oversized))
        try handle.close()
        await #expect(throws: ImportedPhotoVideo.ImportError.tooLarge) {
            _ = try await ImportedPhotoVideo.importFile(at: source)
        }
        #expect(FileManager.default.fileExists(atPath: source.path), "never remove the Photos-owned source")
    }

    @Test func cancelledPhotoVideoImportDoesNotProduceAnOwnedCopy() async throws {
        let source = try await photoVideoSource(name: "cancelled.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await ImportedPhotoVideo.importFile(at: source)
        }
        await #expect(throws: CancellationError.self) { _ = try await operation.value }
        #expect(FileManager.default.fileExists(atPath: source.path), "cancellation must not remove the provider's original")
    }

    @Test func photoVideoCancelledBeforePublicationNeverReachesComposer() async throws {
        let source = try await photoVideoSource(name: "cancelled-before-publication.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let pipeline = ConversationAttachmentPipeline()
        var importedURL: URL?
        let operation = Task {
            let video = try await ImportedPhotoVideo.importFile(at: source)
            importedURL = video.url
            withUnsafeCurrentTask { $0?.cancel() }
            try pipeline.addVideo(video, workspaceId: "ws")
        }
        await #expect(throws: CancellationError.self) { try await operation.value }
        #expect(pipeline.pendingFiles.isEmpty)
        let url = try #require(importedURL)
        try await waitUntil("cancelled video cleanup before composer publication") {
            !FileManager.default.fileExists(atPath: url.path)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test(arguments: [false, true])
    func filesVideoLimitIsCheckedBeforeUploadEvenIfFileGrew(grewAfterPicking: Bool) async throws {
        let source = try await photoVideoSource(name: "huge.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let fake = FakeConnectionManager()
        let pipeline = ConversationAttachmentPipeline(uploadService: AttachmentUploadService(connection: fake))
        if grewAfterPicking { pipeline.addFiles([source]) }
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(ImportedPhotoVideo.maxBytes + 1))
        try handle.close()
        if !grewAfterPicking { pipeline.addFiles([source]) }
        await #expect(throws: ImportedPhotoVideo.ImportError.tooLarge) {
            _ = try await pipeline.buildFileBlocks(from: pipeline.pendingFiles, workspaceId: "ws")
        }
        #expect(ImportedPhotoVideo.ImportError.tooLarge.localizedDescription.contains("max 200 MB"))
        #expect(fake.requestLog.isEmpty)
        #expect(pipeline.pendingFiles.count == 1)
    }

    @Test(arguments: [false, true])
    func photoVideoCleanupOnRemovalOrComposerRelease(releaseComposer: Bool) async throws {
        let source = try await photoVideoSource(name: "recording.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        var pipeline: ConversationAttachmentPipeline? = ConversationAttachmentPipeline()
        try pipeline?.addVideo(try await ImportedPhotoVideo.importFile(at: source), workspaceId: "ws")
        let importedURL = try #require(pipeline?.pendingFiles.first?.url)
        if releaseComposer { pipeline = nil } else { pipeline?.removePendingFile(at: 0) }
        try await waitUntil("imported video cleanup after removal") {
            !FileManager.default.fileExists(atPath: importedURL.path)
        }
        #expect(FileManager.default.fileExists(atPath: source.path))
    }

    @Test func assistantRejectsPhotoAndFilesVideoWithoutUploading() async throws {
        let source = try await photoVideoSource(name: "recording.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        let video = try await ImportedPhotoVideo.importFile(at: source)
        let fake = FakeConnectionManager()
        let pipeline = ConversationAttachmentPipeline(uploadService: AttachmentUploadService(connection: fake))
        do {
            try pipeline.addVideo(video, workspaceId: Workspace.chiefWorkspaceId)
            Issue.record("Assistant must reject Photos videos")
        } catch {
            #expect(error.localizedDescription.contains("not in the Assistant"))
        }
        #expect(pipeline.pendingFiles.isEmpty)
        pipeline.addFiles([source])
        do {
            _ = try await pipeline.buildFileBlocks(from: pipeline.pendingFiles, workspaceId: Workspace.chiefWorkspaceId)
            Issue.record("Assistant must also reject videos picked from Files")
        } catch {
            #expect(error.localizedDescription.contains("not in the Assistant"))
        }
        #expect(fake.requestLog.isEmpty)
    }
}

extension ConversationViewModelTests {
    @Test(arguments: [false, true])
    func photoVideoSendRetainsRemovedFileDuringUploadAndCleansAfterSend(largeVideo: Bool) async throws {
        let source = try await photoVideoSource(name: "recording.mp4")
        defer { try? FileManager.default.removeItem(at: source.deletingLastPathComponent()) }
        if largeVideo {
            let handle = try FileHandle(forWritingTo: source)
            try handle.truncate(atOffset: UInt64(AttachmentUploadService.maxSingleShotBytes + 1))
            try handle.close()
        }
        let (model, fake) = makeFakeBackedVM()
        let size = try #require(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let response: [String: Any] = [
            "attachmentId": "video-1", "fileName": "recording.mp4", "mimeType": "video/mp4",
            "size": size, "path": ".intent/attachments/video-1/recording.mp4"
        ]
        let pendingMethod = "file.attachmentUpload.chunk"
        fake.pendingMethods.insert(pendingMethod)
        fake.responseMap["file.attachmentUpload.begin"] = [
            "uploadId": "upload-1", "maxChunkBytes": AttachmentUploadService.uploadChunkBytes
        ]
        fake.responseMap["file.attachmentUpload.commit"] = response
        fake.responseMap["file.attachmentUpload.chunk"] = [:]
        try model.attachmentPipeline.addVideo(try await ImportedPhotoVideo.importFile(at: source), workspaceId: "test-ws")
        let importedURL = try #require(model.pendingFiles.first?.url)
        let fileId = try #require(model.pendingFiles.first?.id)
        let send = Task { await model.sendMessage("Watch this recording") }
        defer { send.cancel() }
        try await fake.waitForPendingRequests(pendingMethod)
        #expect(model.fileUploadProgress[fileId] == 0)
        model.removePendingFile(at: 0)
        #expect(FileManager.default.fileExists(atPath: importedURL.path), "send attempt must own the removed file")
        fake.pendingMethods.remove(pendingMethod)
        fake.resolvePending(pendingMethod, with: [:])
        await send.value

        let params = try #require(fake.paramsForMethod("agent.sendMessage").first)
        let blocks = try #require(params["fileBlocks"] as? [[String: Any]])
        #expect(blocks[0]["mimeType"] as? String == "video/mp4")
        #expect(blocks[0]["type"] as? String == "file")
        #expect(model.pendingFiles.isEmpty)
        #expect(model.fileUploadProgress.isEmpty)
        #expect(model.store.sendAttempts.first?.status == .accepted)
        #expect(fake.didCallMethod("file.attachmentUpload.begin"))
        try await waitUntil("imported video cleanup after confirmed send") {
            !FileManager.default.fileExists(atPath: importedURL.path)
        }
    }
}

@MainActor
private func photoVideoSource(name: String) async throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("photo-video-test-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let source = directory.appendingPathComponent(name)
    try await IntentFileVideoTests.videoBytes().write(to: source)
    return source
}
