import Foundation
@testable import Intent
import Testing
import UIKit

/// Covers the attachment-reference resolution path: `file.getAttachmentInfo`
/// → workspace-relative path → `file.readChunk` bytes, plus path caching,
/// the missing-file and malformed arms, uncached resolution failures, and
/// the retry path clearing the byte-fetch negative cache.
@MainActor
struct AttachmentImageLoaderTests {
    private typealias LoadError = AttachmentImageLoader.LoadError

    /// A tiny valid PNG rendered at test time.
    private static func pngBytes() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private static func infoResponse(path: String, exists: Bool = true) -> [String: Any] {
        [
            "attachmentId": "att-1",
            "fileName": "pic.png",
            "size": 10,
            "uploadedAt": "2026-01-01T00:00:00Z",
            "path": path,
            "exists": exists
        ]
    }

    private static func chunkResponse(_ chunk: Data) -> [String: Any] {
        ["content": chunk.base64EncodedString(), "bytesRead": chunk.count, "size": chunk.count]
    }

    private static func makeLoader(_ fake: FakeConnectionManager) -> AttachmentImageLoader {
        AttachmentImageLoader(
            connection: fake,
            fileLoader: WorkspaceFileImageLoader(connection: fake)
        )
    }

    @Test func resolvesPathAndFetchesImage() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(path: ".intent/attachments/pic.png")
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png)
        let loader = Self.makeLoader(fake)

        let image = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")

        #expect(image.size.width > 0)
        let infoParams = fake.paramsForMethod("file.getAttachmentInfo")
        #expect(infoParams.count == 1)
        #expect(infoParams[0]["attachmentId"] as? String == "att-1")
        let chunkParams = fake.paramsForMethod("file.readChunk")
        #expect(chunkParams[0]["workspaceId"] as? String == "ws-1")
        #expect(chunkParams[0]["path"] as? String == ".intent/attachments/pic.png")
    }

    @Test func secondLoadReusesCachedPath() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(path: ".intent/attachments/pic.png")
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png)
        let loader = Self.makeLoader(fake)

        let first = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")
        let second = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")

        #expect(first === second)
        #expect(fake.paramsForMethod("file.getAttachmentInfo").count == 1)
        #expect(fake.paramsForMethod("file.readChunk").count == 1)
    }

    @Test func missingFileThrowsFileMissing() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(
            path: ".intent/attachments/pic.png",
            exists: false
        )
        let loader = Self.makeLoader(fake)

        await #expect(throws: LoadError.fileMissing) {
            _ = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")
        }
        #expect(fake.paramsForMethod("file.readChunk").isEmpty)
    }

    @Test func malformedInfoThrowsMalformedResponse() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.getAttachmentInfo"] = ["attachmentId": "att-1"]
        let loader = Self.makeLoader(fake)

        await #expect(throws: LoadError.malformedResponse) {
            _ = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")
        }
    }

    @Test func resolutionFailureIsNotCached() async throws {
        // FE parity (attachment-image-url.ts): a transient resolution error
        // retries on the next render pass.
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.errorMap["file.getAttachmentInfo"] = NSError(domain: "test", code: -1)
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png)
        let loader = Self.makeLoader(fake)

        _ = try? await loader.image(workspaceId: "ws-1", attachmentId: "att-1")

        fake.errorMap.removeValue(forKey: "file.getAttachmentInfo")
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(path: ".intent/attachments/pic.png")
        let image = try await loader.image(workspaceId: "ws-1", attachmentId: "att-1")

        #expect(image.size.width > 0)
        #expect(fake.paramsForMethod("file.getAttachmentInfo").count == 2)
    }

    @Test func retryClearsByteFetchNegativeCache() async throws {
        // First load resolves the path but the byte fetch fails, which the
        // file loader negatively caches for the session; retryImage clears
        // that entry so the fetch genuinely re-runs.
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(path: ".intent/attachments/pic.png")
        fake.errorMap["file.readChunk"] = NSError(domain: "test", code: -1)
        let loader = Self.makeLoader(fake)

        _ = try? await loader.image(workspaceId: "ws-1", attachmentId: "att-1")

        fake.errorMap.removeValue(forKey: "file.readChunk")
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png)
        let image = try await loader.retryImage(workspaceId: "ws-1", attachmentId: "att-1")

        #expect(image.size.width > 0)
        #expect(fake.paramsForMethod("file.readChunk").count == 2)
    }

    @Test func concurrentLoadsShareOneResolution() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.delayMap["file.getAttachmentInfo"] = 50_000_000
        fake.responseMap["file.getAttachmentInfo"] = Self.infoResponse(path: ".intent/attachments/pic.png")
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png)
        let loader = Self.makeLoader(fake)

        async let firstLoad = loader.image(workspaceId: "ws-1", attachmentId: "att-1")
        async let secondLoad = loader.image(workspaceId: "ws-1", attachmentId: "att-1")
        let (first, second) = try await (firstLoad, secondLoad)

        #expect(first === second)
        #expect(fake.paramsForMethod("file.getAttachmentInfo").count == 1)
    }
}
