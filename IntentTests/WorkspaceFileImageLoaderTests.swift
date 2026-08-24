import Foundation
import Testing
import UIKit
@testable import Intent

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
            Self.chunkResponse(Data(second), size: png.count),
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
            "content": Data([1, 2, 3]).base64EncodedString(), "bytesRead": 99, "size": 3,
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
            "size": WorkspaceFileImageLoader.maxFileBytes + 1,
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
}
