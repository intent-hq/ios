import Foundation
@testable import Intent
import Synchronization
import Testing
import UIKit

/// Send-time photo encoding runs off the main actor and keeps its limits.
@MainActor
struct ConversationAttachmentEncodingTests {
    private typealias PlacementError = ConversationAttachmentPipeline.ImagePlacementError

    @Test func encoderRunsOffMainThreadAndKeepsOrderAndBytes() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let star = try #require(UIImage(systemName: "star"))
        let circle = try #require(UIImage(systemName: "circle"))
        let encodedOnMainThread = Mutex<[Bool]>([])
        pipeline.encodeOutgoingJPEG = { image in
            encodedOnMainThread.withLock { $0.append(Thread.isMainThread) }
            return ConversationAttachmentPipeline.outgoingJPEGData(for: image)
        }

        let payload = try await pipeline.buildImageBlocks(from: [star, circle], workspaceId: Workspace.chiefWorkspaceId)

        #expect(encodedOnMainThread.withLock { $0 } == [false, false])
        guard case let .inline(blocks) = payload else {
            Issue.record("Assistant images must be inline blocks")
            return
        }
        let sent = try blocks.map { block in
            let encoded = try #require(block["data"] as? String)
            return try #require(Data(base64Encoded: encoded))
        }
        let expected = [star, circle].map(ConversationAttachmentPipeline.outgoingJPEGData(for:))
        #expect(sent == expected)
    }

    @Test func oversizedEncodedImageStillFailsAsImageTooLarge() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let star = try #require(UIImage(systemName: "star"))
        let calls = Mutex(0)
        pipeline.encodeOutgoingJPEG = { image in
            let call = calls.withLock { count in
                count += 1
                return count
            }
            return call == 1 ? ConversationAttachmentPipeline.outgoingJPEGData(for: image) : Data(count: 1024 * 1024 + 1)
        }

        let error = await #expect(throws: PlacementError.self) {
            try await pipeline.buildImageBlocks(from: [star, star], workspaceId: Workspace.chiefWorkspaceId)
        }

        guard case .imageTooLarge(index: 2)? = error else {
            Issue.record("Expected imageTooLarge for image 2, got \(String(describing: error))")
            return
        }
    }

    @Test func cancelledSendStopsEncodingRemainingImages() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let star = try #require(UIImage(systemName: "star"))
        let calls = Mutex(0)
        pipeline.encodeOutgoingJPEG = { image in
            calls.withLock { $0 += 1 }
            withUnsafeCurrentTask { $0?.cancel() }
            return ConversationAttachmentPipeline.outgoingJPEGData(for: image)
        }

        let send = Task {
            try await pipeline.buildImageBlocks(from: [star, star, star], workspaceId: Workspace.chiefWorkspaceId)
        }

        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(calls.withLock { $0 } == 1)
    }
}
