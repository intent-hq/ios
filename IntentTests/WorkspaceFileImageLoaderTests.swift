import Foundation
@testable import Intent
import Testing
import UIKit

/// Covers the `file.readChunk` fetch path: chunk assembly, malformed
/// responses, the size cap, decode failure, and caching.
@MainActor
struct WorkspaceFileImageLoaderTests {
    private typealias LoadError = WorkspaceFileImageLoader.LoadError

    /// A tiny valid PNG rendered at test time.
    private static func pngBytes() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 4))
        return renderer.pngData { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        }
    }

    private static func chunkResponse(_ chunk: Data, size: Int) -> [String: Any] {
        ["content": chunk.base64EncodedString(), "bytesRead": chunk.count, "size": size]
    }

    @Test func singleChunkFetchDecodesImage() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png, size: png.count)
        let loader = WorkspaceFileImageLoader(connection: fake)

        let image = try await loader.image(workspaceId: "ws-1", path: "pic.png")

        #expect(image.size.width > 0)
        let params = fake.paramsForMethod("file.readChunk")
        #expect(params.count == 1)
        #expect(params[0]["workspaceId"] as? String == "ws-1")
        #expect(params[0]["path"] as? String == "pic.png")
        #expect(params[0]["offset"] as? Int == 0)
    }

    @Test func multiChunkResponsesAreAssembledInOrder() async throws {
        let png = Self.pngBytes()
        let mid = png.count / 2
        let first = png.prefix(mid)
        let second = png.suffix(from: mid)
        let fake = FakeConnectionManager()
        fake.responseQueueMap["file.readChunk"] = [
            Self.chunkResponse(Data(first), size: png.count),
            Self.chunkResponse(Data(second), size: png.count)
        ]
        let loader = WorkspaceFileImageLoader(connection: fake)

        let image = try await loader.image(workspaceId: "ws-1", path: "pic.png")

        #expect(image.size.width > 0)
        let params = fake.paramsForMethod("file.readChunk")
        #expect(params.count == 2)
        #expect(params[0]["offset"] as? Int == 0)
        #expect(params[1]["offset"] as? Int == mid)
    }

    @Test func missingFieldsThrowMalformedResponse() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = ["content": "AAAA"]
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.malformedResponse) {
            _ = try await loader.image(workspaceId: "ws-1", path: "pic.png")
        }
    }

    @Test func bytesReadMismatchThrowsMalformedResponse() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = [
            "content": Data([1, 2, 3]).base64EncodedString(), "bytesRead": 99, "size": 3
        ]
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.malformedResponse) {
            _ = try await loader.image(workspaceId: "ws-1", path: "pic.png")
        }
    }

    @Test func oversizedFileThrowsFileTooLarge() async {
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = [
            "content": Data([1]).base64EncodedString(), "bytesRead": 1,
            "size": WorkspaceFileImageLoader.maxFileBytes + 1
        ]
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.fileTooLarge) {
            _ = try await loader.image(workspaceId: "ws-1", path: "huge.png")
        }
    }

    @Test func undecodableBytesThrowNotAnImage() async {
        let text = Data("not an image".utf8)
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = Self.chunkResponse(text, size: text.count)
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.notAnImage) {
            _ = try await loader.image(workspaceId: "ws-1", path: "fake.png")
        }
    }

    @Test func failedFetchIsNegativelyCachedForTheSession() async {
        let fake = FakeConnectionManager()
        fake.errorMap["file.readChunk"] = NSError(domain: "test", code: -1)
        let loader = WorkspaceFileImageLoader(connection: fake)

        _ = try? await loader.image(workspaceId: "ws-1", path: "broken.png")
        await #expect(throws: LoadError.previouslyFailed) {
            _ = try await loader.image(workspaceId: "ws-1", path: "broken.png")
        }
        #expect(fake.paramsForMethod("file.readChunk").count == 1)
    }

    @Test func transientConnectionDropDoesNotPoisonNegativeCache() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.errorMap["file.readChunk"] = ConnectionManager.notConnectedRequestError()
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: (any Error).self) {
            _ = try await loader.image(workspaceId: "ws-1", path: "reconnect.png")
        }
        #expect(loader.failedKeys.isEmpty, "Read-only / transient disconnect errors must not poison failedKeys")

        fake.errorMap["file.readChunk"] = nil
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png, size: png.count)
        let image = try await loader.image(workspaceId: "ws-1", path: "reconnect.png")
        #expect(image.size.width > 0)
        #expect(fake.paramsForMethod("file.readChunk").count == 2)
    }

    @Test func secondRequestForSameFileIsServedFromCache() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png, size: png.count)
        let loader = WorkspaceFileImageLoader(connection: fake)

        let first = try await loader.image(workspaceId: "ws-1", path: "pic.png")
        let second = try await loader.image(workspaceId: "ws-1", path: "pic.png")

        #expect(first === second)
        #expect(fake.paramsForMethod("file.readChunk").count == 1)
    }

    // MARK: - Workspace assets (`note.readAsset`)

    private static func assetResponse(_ bytes: Data, assetId: String = "a1-b2.png") -> [String: Any] {
        [
            "assetId": assetId, "mimeType": "image/png",
            "data": bytes.base64EncodedString(), "sizeKb": 1
        ]
    }

    @Test func assetFetchReadsTheAssetOverNoteReadAsset() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["note.readAsset"] = Self.assetResponse(png)
        let loader = WorkspaceFileImageLoader(connection: fake)

        let image = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")

        #expect(image.size.width > 0)
        let params = fake.paramsForMethod("note.readAsset")
        #expect(params.count == 1)
        #expect(params[0]["workspaceId"] as? String == "ws-1")
        #expect(params[0]["asset"] as? String == "a1-b2.png")
        #expect(fake.paramsForMethod("file.readChunk").isEmpty)
    }

    @Test func assetResponseWithoutDataThrowsMalformedResponse() async {
        let fake = FakeConnectionManager()
        fake.responseMap["note.readAsset"] = ["assetId": "a1-b2.png", "mimeType": "image/png"]
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.malformedResponse) {
            _ = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        }
    }

    @Test func assetResponseWithInvalidBase64ThrowsMalformedResponse() async {
        let fake = FakeConnectionManager()
        fake.responseMap["note.readAsset"] = [
            "assetId": "a1-b2.png", "mimeType": "image/png", "data": "%%not-base64%%", "sizeKb": 0
        ]
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.malformedResponse) {
            _ = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        }
    }

    @Test func undecodableAssetBytesThrowNotAnImage() async {
        let fake = FakeConnectionManager()
        fake.responseMap["note.readAsset"] = Self.assetResponse(Data("not an image".utf8))
        let loader = WorkspaceFileImageLoader(connection: fake)

        await #expect(throws: LoadError.notAnImage) {
            _ = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        }
    }

    @Test func assetImageIsCachedPerAssetIdAndRefetchedWhenTheIdChanges() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["note.readAsset"] = Self.assetResponse(png)
        let loader = WorkspaceFileImageLoader(connection: fake)

        let first = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        let second = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        #expect(first === second)
        #expect(fake.paramsForMethod("note.readAsset").count == 1)

        // A replaced status image is a new content-addressed id: it must
        // fetch again rather than serve the previous screenshot.
        let replaced = try await loader.assetImage(workspaceId: "ws-1", assetId: "c3-d4.png")
        #expect(replaced !== first)
        let params = fake.paramsForMethod("note.readAsset")
        #expect(params.count == 2)
        #expect(params[1]["asset"] as? String == "c3-d4.png")
    }

    @Test func failedAssetFetchIsNegativelyCachedUntilForgotten() async throws {
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.errorMap["note.readAsset"] = NSError(domain: "test", code: -1)
        let loader = WorkspaceFileImageLoader(connection: fake)

        _ = try? await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        await #expect(throws: LoadError.previouslyFailed) {
            _ = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        }
        #expect(fake.paramsForMethod("note.readAsset").count == 1)

        // A user-initiated retry clears the negative entry and refetches.
        fake.errorMap["note.readAsset"] = nil
        fake.responseMap["note.readAsset"] = Self.assetResponse(png)
        loader.forgetAssetFailure(workspaceId: "ws-1", assetId: "a1-b2.png")
        let image = try await loader.assetImage(workspaceId: "ws-1", assetId: "a1-b2.png")
        #expect(image.size.width > 0)
        #expect(fake.paramsForMethod("note.readAsset").count == 2)
    }

    @Test func assetAndFileCachesDoNotCollide() async throws {
        // The same string as a file path and as an asset id are different
        // resources; a cached file image must not answer an asset request.
        let png = Self.pngBytes()
        let fake = FakeConnectionManager()
        fake.responseMap["file.readChunk"] = Self.chunkResponse(png, size: png.count)
        fake.responseMap["note.readAsset"] = Self.assetResponse(png, assetId: "pic.png")
        let loader = WorkspaceFileImageLoader(connection: fake)

        _ = try await loader.image(workspaceId: "ws-1", path: "pic.png")
        _ = try await loader.assetImage(workspaceId: "ws-1", assetId: "pic.png")

        #expect(fake.paramsForMethod("file.readChunk").count == 1)
        #expect(fake.paramsForMethod("note.readAsset").count == 1)
    }
}
