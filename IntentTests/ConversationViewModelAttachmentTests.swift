import Foundation
@testable import Intent
import Observation
import Synchronization
import Testing
import UIKit

extension ConversationViewModelTests {
    // MARK: - Image placement (attachment references, monorepo#3338)

    @Test(arguments: [false, true])
    func assistantImagesReachSendAndQueueWithoutWorkspacePlacement(queue: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: Workspace.chiefWorkspaceId)
        fake.errorMap["file.placeAttachment"] = NSError(domain: "WebSocket", code: -32_603)
        fake.responseMap["agent.queueMessage"] = [
            "queuedMessage": ["id": "queued-image", "content": "File issue for this", "createdAt": "2026-09-30T00:00:00Z"]
        ]
        let image = try #require(UIImage(systemName: "star"))
        viewModel.pendingImages = [image]

        if queue {
            await viewModel.queueMessage("File issue for this")
        } else {
            await viewModel.sendMessage("File issue for this")
        }

        #expect(!fake.requestLog.contains { $0.method.hasPrefix("file.") })
        let requests = fake.paramsForMethod(queue ? "agent.queueMessage" : "agent.sendMessage")
        #expect(requests.count == 1)
        let params = try #require(requests.first)
        #expect(params["content"] as? String == "File issue for this")
        let blocks = try #require(params["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "image")
        #expect(blocks[0]["mimeType"] as? String == "image/jpeg")
        #expect(blocks[0]["attachmentId"] == nil)
        let encoded = try #require(blocks[0]["data"] as? String)
        let data = try #require(Data(base64Encoded: encoded))
        #expect(UIImage(data: data) != nil, "the transmitted bytes must decode as an image")
        #expect(data == image.jpegData(compressionQuality: Constants.Conversation.Composer.imageCompressionQuality))
        #expect(viewModel.pendingImages.isEmpty)
        #expect(viewModel.imagePlacementError == nil)
        if !queue { #expect(viewModel.store.sendAttempts.first?.status == .accepted) }
    }

    @Test(arguments: [false, true])
    func assistantOversizedRequestPreservesTextAndImagesWithoutDispatch(queue: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: Workspace.chiefWorkspaceId)
        let image = try #require(UIImage(systemName: "star"))
        // Escaped text alone fills the 40 MiB wire limit, before image/envelope overhead.
        let text = String(repeating: "\"", count: 20 * 1024 * 1024)
        viewModel.messageText = ""
        if queue {
            viewModel.pendingImages = [image]
            await viewModel.queueMessage(text)
        } else {
            await viewModel.sendMessage(text, images: [image])
        }

        let noRequests = fake.requestLog.isEmpty
        #expect(noRequests)
        #expect(viewModel.imagePlacementError?.contains("too large") == true)
        let restoredText = viewModel.messageText == text
        #expect(restoredText)
        #expect(viewModel.pendingImages.first === image)
        if !queue {
            #expect(viewModel.sendRecoveryAttempts.first?.status == .notSent)
            #expect(viewModel.sendRecoveryAttempts.first?.images.first === image)
            #expect(viewModel.sendRecoveryAttempts.first?.canRetry == false, "edit the oversized selection before resending")
        }
        viewModel.messageText = ""
    }

    @Test(arguments: [false, true])
    func inlineImageRequestLimitIncludesBase64AndEnvelope(queue: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: Workspace.chiefWorkspaceId)
        // A legal 30 MiB raw payload expands to 40 MiB before JSON overhead.
        let payload = OutgoingImagePayload.inline([
            ["type": "image", "mimeType": "image/jpeg", "data": String(repeating: "A", count: 40 * 1024 * 1024)]
        ])
        await #expect(throws: OutgoingImagePayload.RequestError.tooLarge) {
            if queue {
                try await viewModel.store.queueMessage(agentId: "test-agent", content: "with image", imagePayload: payload)
            } else {
                try await viewModel.store.sendMessage(
                    agentId: "test-agent", content: "with image", workspaceId: Workspace.chiefWorkspaceId, imagePayload: payload
                )
            }
        }
        let noRequests = fake.requestLog.isEmpty
        #expect(noRequests)
    }

    @Test(arguments: [false, true], [false, true])
    func encodingFailureKeepsWholeDraftWithoutDispatch(assistant: Bool, queue: Bool) async throws {
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: assistant ? Workspace.chiefWorkspaceId : "test-ws")
        viewModel.messageText = ""
        let valid = try #require(UIImage(systemName: "star"))
        let image = UIImage()
        viewModel.pendingImages = [valid, image]
        if queue {
            await viewModel.queueMessage("keep my draft")
        } else {
            await viewModel.sendMessage("keep my draft")
        }
        #expect(fake.requestLog.isEmpty)
        #expect(viewModel.imagePlacementError != nil)
        #expect(viewModel.messageText == "keep my draft")
        #expect(viewModel.pendingImages.count == 2)
        #expect(viewModel.pendingImages.first === valid)
        #expect(viewModel.pendingImages.last === image)
        if !queue { #expect(viewModel.sendRecoveryAttempts.first?.status == .notSent) }
    }

    @Test func buildImageBlocksPlacesImagesAndBuildsReferenceBlocks() async throws {
        // Ordinary workspaces place images (`file.placeAttachment`) and the wire
        // block is `{ type: "image", attachmentId, mimeType }` — never
        // inline base64 (FE parity: toImageReferenceBlocks).
        let (viewModel, fake) = makeFakeBackedVM()

        await viewModel.sendMessage("with image", images: [try #require(UIImage(systemName: "star"))])

        let placement = try #require(
            fake.requestLog.last { $0.method == "file.placeAttachment" }
        )
        #expect(placement.params["workspaceId"] as? String == "test-ws")
        #expect(placement.params["mimeType"] as? String == "image/jpeg")
        #expect((placement.params["fileName"] as? String)?.hasSuffix(".jpg") == true)

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let blocks = try #require(sent.params["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "image")
        #expect(blocks[0]["attachmentId"] as? String == "att-1")
        #expect(blocks[0]["mimeType"] as? String == "image/jpeg")
        #expect(blocks[0]["data"] == nil, "no inline data key for placed images")
    }

    @Test func failedPlacementSurfacesErrorAndDoesNotSend() async throws {
        // FAIL-CLOSED (FE parity): a placement failure aborts the send — no
        // agent.sendMessage goes out, the error surfaces, and the composer
        // state (text + captured images) is restored.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket",
            code: -32_000,
            userInfo: [NSLocalizedDescriptionKey: "registry full"]
        )

        await viewModel.sendMessage("with image", images: [try #require(UIImage(systemName: "star"))])

        #expect(
            fake.requestLog.allSatisfy { $0.method != "agent.sendMessage" },
            "the message is never sent when placement fails"
        )
        #expect(viewModel.imagePlacementError != nil)
        #expect(viewModel.messageText == "with image", "draft text restored")
        #expect(viewModel.pendingImages.count == 1, "captured images restored")
    }

    @Test(arguments: [(false, false), (false, true), (true, false), (true, true)], [false, true])
    func largePhotosReachSendAndQueueWithinClientBudget(route: (Bool, Bool), highResolution: Bool) async throws {
        let (assistant, queue) = route
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: assistant ? Workspace.chiefWorkspaceId : "test-ws")
        fake.responseMap["agent.queueMessage"] = [:] as [String: Any]
        // The scale-3 rectangular case catches point/pixel confusion. The
        // 2048-square case already meets the edge cap but exceeds the byte cap.
        let width = highResolution ? 4096 : 2048
        let source = try makeIncompressibleImage(width: width, height: 2048)
        let image = UIImage(cgImage: try #require(source.cgImage), scale: 3, orientation: .right)
        let original = try #require(image.jpegData(compressionQuality: 0.8))
        try #require(original.count > 1024 * 1024, "fixture must exercise byte reduction")
        viewModel.pendingImages = Array(repeating: image, count: 5)
        if queue { await viewModel.queueMessage("big photos") } else { await viewModel.sendMessage("big photos") }

        let requests = fake.paramsForMethod(queue ? "agent.queueMessage" : "agent.sendMessage")
        #expect(requests.count == 1)
        let params = try #require(requests.first)
        #expect(params["content"] as? String == "big photos")
        let blocks = try #require(params["imageBlocks"] as? [[String: Any]])
        #expect(blocks.count == 5, "never silently omit an image to meet the budget")
        let placements = fake.paramsForMethod("file.placeAttachment")
        #expect(placements.count == (assistant ? 0 : 5))
        #expect(blocks.allSatisfy { ($0["attachmentId"] != nil) == !assistant })
        let payloads = try (assistant ? blocks : placements).map { block in
            let encoded = try #require(block["data"] as? String)
            return try #require(Data(base64Encoded: encoded))
        }
        #expect(payloads.reduce(0) { $0 + $1.count } <= 5 * 1024 * 1024)
        for data in payloads {
            #expect(data.count <= 1024 * 1024)
            let decoded = try #require(UIImage(data: data))
            let pixels = try #require(decoded.cgImage)
            #expect(decoded.imageOrientation == .up)
            #expect(max(pixels.width, pixels.height) <= 2048)
            #expect(min(pixels.width, pixels.height) > 0)
            #expect(abs(Double(pixels.width) / Double(pixels.height) - 2048.0 / Double(width)) < 0.002)
        }
        #expect(image.cgImage?.width == width, "original photo is not replaced with the resized version")
        #expect(image.imageOrientation == .right)
        #expect(viewModel.pendingImages.isEmpty)
        #expect(viewModel.imagePlacementError == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func aggregateOversizedImagesSurfaceErrorBeforeAnyPlacement(assistant: Bool, queue: Bool) async throws {
        // A programmatic/recovered selection can bypass the picker's count
        // limit. The actual JPEG budget must still be enforced before any RPC.
        let (viewModel, fake) = makeFakeBackedVM(workspaceId: assistant ? Workspace.chiefWorkspaceId : "test-ws")
        let image = try makeIncompressibleImage(width: 1024, height: 1024)
        viewModel.messageText = ""
        viewModel.pendingImages = Array(repeating: image, count: 32)
        if queue { await viewModel.queueMessage("big batch") } else { await viewModel.sendMessage("big batch") }

        let noRequests = fake.requestLog.isEmpty
        #expect(noRequests, "no RPC at all for an aggregate-oversized send")
        #expect(viewModel.imagePlacementError?.contains("too large") == true)
        #expect(viewModel.messageText == "big batch")
        #expect(viewModel.pendingImages.count == 32, "the whole selection survives rejection")
        #expect(viewModel.pendingImages.allSatisfy { $0 === image })
        if !queue { #expect(viewModel.sendRecoveryAttempts.first?.status == .notSent) }
    }

    @Test func queueMessageFailedPlacementKeepsPendingImages() async throws {
        // The queue path never pre-clears pendingImages; a placement failure
        // must keep them attached and never reach agent.queueMessage.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket",
            code: -32_000
        )
        viewModel.addImage(try #require(UIImage(systemName: "star")))

        await viewModel.queueMessage("queued with image")

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.queueMessage" })
        #expect(viewModel.imagePlacementError != nil)
        #expect(viewModel.pendingImages.count == 1)
    }

    @Test func queueMessagePlacesImagesAndClearsPending() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.queueMessage"] = [:] as [String: Any]
        viewModel.addImage(try #require(UIImage(systemName: "star")))

        await viewModel.queueMessage("queued with image")

        let queued = try #require(fake.requestLog.last { $0.method == "agent.queueMessage" })
        let blocks = try #require(queued.params["imageBlocks"] as? [[String: Any]])
        #expect(blocks[0]["attachmentId"] as? String == "att-1")
        #expect(blocks[0]["data"] == nil)
        #expect(viewModel.pendingImages.isEmpty)
    }

    @Test func sendMessageWithoutImagesSkipsPlacement() async throws {
        // Text-only sends never touch the attachment registry.
        let (viewModel, fake) = makeFakeBackedVM()

        await viewModel.sendMessage("plain text")

        #expect(fake.requestLog.allSatisfy { $0.method != "file.placeAttachment" })
        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        #expect(sent.params["imageBlocks"] == nil)
        #expect(sent.params["fileBlocks"] == nil)
    }
}

extension ConversationViewModelTests {
    // MARK: - File placement (send-time uploads)

    @Test func sendMessagePlacesFilesAndBuildsFileBlocks() async throws {
        // Sending with a pending file places it (`file.placeAttachment`,
        // single-shot under 25 MB) and the wire block is
        // `{ type: "file", attachmentId, fileName, mimeType, size }`; the
        // pending list clears only after the successful send.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-f1",
            "fileName": "notes.txt",
            "path": ".intent/attachments/att-f1/notes.txt",
            "size": 5,
            "mimeType": "text/plain"
        ] as [String: Any]
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        viewModel.addFiles([url])

        await viewModel.sendMessage("with file")

        let placement = try #require(
            fake.requestLog.last { $0.method == "file.placeAttachment" }
        )
        #expect(placement.params["workspaceId"] as? String == "test-ws")
        #expect(placement.params["fileName"] as? String == "notes.txt")
        #expect(placement.params["mimeType"] as? String == "text/plain")

        let sent = try #require(fake.requestLog.last { $0.method == "agent.sendMessage" })
        let blocks = try #require(sent.params["fileBlocks"] as? [[String: Any]])
        #expect(blocks.count == 1)
        #expect(blocks[0]["type"] as? String == "file")
        #expect(blocks[0]["attachmentId"] as? String == "att-f1")
        #expect(blocks[0]["fileName"] as? String == "notes.txt")
        #expect(blocks[0]["mimeType"] as? String == "text/plain")
        #expect(blocks[0]["size"] as? Int == 5)
        #expect(viewModel.pendingFiles.isEmpty, "pending files clear on successful send")
        #expect(viewModel.fileUploadProgress.isEmpty, "progress state cleared after send")
    }

    @Test func failedFilePlacementSurfacesErrorAndDoesNotSend() async throws {
        // FAIL-CLOSED: a file placement failure aborts the send — no
        // agent.sendMessage goes out, the error surfaces, the draft text is
        // restored, and the pending files stay attached.
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket",
            code: -32_000,
            userInfo: [NSLocalizedDescriptionKey: "registry full"]
        )
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        viewModel.addFiles([url])

        await viewModel.sendMessage("with file")

        #expect(
            fake.requestLog.allSatisfy { $0.method != "agent.sendMessage" },
            "the message is never sent when file placement fails"
        )
        #expect(viewModel.filePlacementError != nil)
        #expect(viewModel.messageText == "with file", "draft text restored")
        #expect(viewModel.pendingFiles.count == 1, "pending files stay attached")
        #expect(viewModel.fileUploadProgress.isEmpty, "progress state cleared after failure")
    }

    @Test func oversizedPendingFileFailsWithoutAnyRPC() async {
        // A pending file whose pick-time size exceeds the daemon's 1 GiB cap
        // fails the send client-side with an explicit error.
        let (viewModel, fake) = makeFakeBackedVM()
        viewModel.pendingFiles.append(PendingFile(
            url: URL(fileURLWithPath: "/tmp/huge.bin"),
            displayName: "huge.bin",
            size: Int64(AttachmentUploadService.maxAttachmentBytes) + 1
        ))

        await viewModel.sendMessage("big file")

        #expect(fake.requestLog.isEmpty, "no RPC at all for an oversized file")
        #expect(viewModel.filePlacementError?.contains("too large") == true)
        #expect(viewModel.pendingFiles.count == 1)
    }

    @Test func queueMessagePlacesFilesAndClearsPending() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.responseMap["agent.queueMessage"] = [:] as [String: Any]
        fake.responseMap["file.placeAttachment"] = [
            "attachmentId": "att-f1",
            "fileName": "notes.txt",
            "path": ".intent/attachments/att-f1/notes.txt",
            "size": 5
        ] as [String: Any]
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        viewModel.addFiles([url])

        await viewModel.queueMessage("queued with file")

        let queued = try #require(fake.requestLog.last { $0.method == "agent.queueMessage" })
        let blocks = try #require(queued.params["fileBlocks"] as? [[String: Any]])
        #expect(blocks[0]["attachmentId"] as? String == "att-f1")
        #expect(blocks[0]["mimeType"] == nil, "mimeType omitted when the daemon returns none")
        #expect(viewModel.pendingFiles.isEmpty)
    }
}

extension ConversationViewModelTests {
    @Test func queueMessageFailedFilePlacementKeepsPendingFiles() async throws {
        let (viewModel, fake) = makeFakeBackedVM()
        fake.errorMap["file.placeAttachment"] = NSError(
            domain: "WebSocket",
            code: -32_000
        )
        let url = try makeTempFile(named: "notes.txt", contents: "hello")
        defer { try? FileManager.default.removeItem(at: url) }
        viewModel.addFiles([url])

        await viewModel.queueMessage("queued with file")

        #expect(fake.requestLog.allSatisfy { $0.method != "agent.queueMessage" })
        #expect(viewModel.filePlacementError != nil)
        #expect(viewModel.pendingFiles.count == 1)
    }

    /// Write a small temp file and return its URL (caller removes it).
    private func makeTempFile(named name: String, contents: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    /// High-entropy pixels exercise byte limits independently of dimension limits.
    private func makeIncompressibleImage(width: Int, height: Int) throws -> UIImage {
        let bitsPerComponent = 8
        let bytesPerPixel = 4
        var bytes = Data(count: width * height * bytesPerPixel)
        try bytes.withUnsafeMutableBytes { buffer in
            let baseAddress = try #require(buffer.baseAddress)
            arc4random_buf(baseAddress, buffer.count)
        }
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: width * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        try bytes.withUnsafeBytes { buffer in
            let destination = try #require(context.data)
            let source = try #require(buffer.baseAddress)
            destination.copyMemory(from: source, byteCount: buffer.count)
        }
        return UIImage(cgImage: try #require(context.makeImage()))
    }

    // MARK: - Image handling

    @Test func addImageAppendsToPendingImages() async throws {
        let viewModel = makeVM()
        let img = try #require(UIImage(systemName: "star"))
        viewModel.addImage(img)
        #expect(viewModel.pendingImages.count == 1)
        viewModel.addImage(img)
        #expect(viewModel.pendingImages.count == 2)
    }

    @Test func forwardedAttachmentStateRemainsObservable() throws {
        let viewModel = makeVM()
        let changeCount = Mutex(0)
        withObservationTracking {
            _ = viewModel.pendingImages.count
        } onChange: {
            changeCount.withLock { $0 += 1 }
        }

        viewModel.addImage(try #require(UIImage(systemName: "star")))

        #expect(changeCount.withLock { $0 } == 1)
    }

    @Test func removeImageRemovesAtIndex() async throws {
        let viewModel = makeVM()
        let img1 = try #require(UIImage(systemName: "star"))
        let img2 = try #require(UIImage(systemName: "circle"))
        viewModel.addImage(img1)
        viewModel.addImage(img2)
        viewModel.removeImage(at: 0)
        #expect(viewModel.pendingImages.count == 1)
    }

    @Test func removeImageOutOfBoundsIsSafe() async throws {
        let viewModel = makeVM()
        let img = try #require(UIImage(systemName: "star"))
        viewModel.addImage(img)
        viewModel.removeImage(at: 5)
        #expect(viewModel.pendingImages.count == 1)
        viewModel.removeImage(at: -1)
        #expect(viewModel.pendingImages.count == 1)
    }
}
