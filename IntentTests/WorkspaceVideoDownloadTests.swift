import AVFoundation
import Foundation
@testable import Intent
import Testing
import UIKit

@MainActor
struct WorkspaceVideoDownloadTests {
    @Test func attachmentAtVideoLimitStreamsAndCleansUpAfterLastOwner() async throws {
        let bytes = try await IntentFileVideoTests.videoBytes()
        let total = ImportedPhotoVideo.maxBytes
        let length = WorkspaceFileImageLoader.chunkLength
        // Append a valid MP4 free-space atom without constructing a 200 MB Data.
        var freeSize = UInt32(total - bytes.count).bigEndian
        var first = bytes
        withUnsafeBytes(of: &freeSize) { first.append(contentsOf: $0) }
        first.append(Data("free".utf8))
        first.append(Data(count: length - first.count))
        let padding = Self.chunk(Data(count: length), size: total)
        let connection = FakeConnectionManager()
        connection.responseMap["file.getAttachmentInfo"] = ["path": ".intent/attachments/large.mp4", "exists": true]
        connection.responseQueueMap["file.readChunk"] = [Self.chunk(first, size: total)]
            + Array(repeating: padding, count: total / length - 1)
        var loader: AttachmentImageLoader? = AttachmentImageLoader(
            connection: connection, fileLoader: WorkspaceFileImageLoader(connection: connection)
        )
        var video = try await loader?.video(workspaceId: "ws", attachmentId: "large-video")
        let url = try #require(video?.url)
        #expect(video?.byteCount == total)
        #expect(video?.poster.size.width == 16)
        #expect(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize == total)
        #expect(try await AVURLAsset(url: url).load(.isPlayable))
        let requests = connection.paramsForMethod("file.readChunk")
        #expect(requests.map { $0["offset"] as? Int } == Array(stride(from: 0, to: total, by: length)))

        loader = nil
        #expect(FileManager.default.fileExists(atPath: url.path), "Playback keeps the file alive after cache release")
        video = nil
        try await waitUntil("download removed after its last owner releases it") {
            !FileManager.default.fileExists(atPath: url.path)
        }
    }

    @Test func oversizedVideoIsRejectedBeforeFurtherChunks() async {
        let connection = FakeConnectionManager()
        connection.responseMap["file.readChunk"] = Self.chunk(Data([0]), size: ImportedPhotoVideo.maxBytes + 1)
        let loader = WorkspaceFileImageLoader(connection: connection)

        await #expect(throws: WorkspaceFileImageLoader.LoadError.fileTooLarge) {
            _ = try await loader.video(workspaceId: "ws", path: "oversized.mp4")
        }
        #expect(connection.paramsForMethod("file.readChunk").count == 1)
    }

    @Test(arguments: ["short-read", "changed-size", "oversized-chunk"])
    func malformedVideoDownloadDoesNotPreparePartialFile(_ failure: String) async {
        let connection = FakeConnectionManager()
        let secondSize = failure == "changed-size" ? 3 : 2
        let second = Self.chunk(Data(), size: secondSize)
        connection.responseQueueMap["file.readChunk"] = [Self.chunk(Data([0]), size: 2), second]
        if failure == "oversized-chunk" {
            connection.responseQueueMap["file.readChunk"] = [
                [
                    "content": "AA==", "bytesRead": WorkspaceFileImageLoader.chunkLength + 1,
                    "size": ImportedPhotoVideo.maxBytes
                ]
            ]
        }
        let loader = WorkspaceFileImageLoader(connection: connection)
        await #expect(throws: WorkspaceFileImageLoader.LoadError.malformedResponse) {
            _ = try await loader.video(workspaceId: "ws", path: "partial.mp4")
        }
    }

    @Test(arguments: [false, true])
    func failedOrCancelledPreparationRemovesOwnedTemporaryFile(_ cancelled: Bool) async throws {
        let url = try WorkspaceVideo.temporaryURL(path: "invalid.mp4")
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task { try await WorkspaceVideo.prepare(fileURL: url, byteCount: 1) }
        if cancelled { task.cancel() }
        do {
            _ = try await task.value
            Issue.record("An invalid or cancelled video must not be prepared")
        } catch {
            if cancelled { #expect(error is CancellationError) }
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    // #883: UTType treats .ts/.mts as MPEG transport streams.
    @Test(arguments: ["Web/collector.ts", "src/index.mts", "LIB/TYPES.TS"])
    func typeScriptPathsWithoutVideoMIMEAreNotVideo(_ path: String) {
        #expect(!WorkspaceVideo.isVideo(path: path))
        #expect(!WorkspaceVideo.isVideo(path: path, mimeType: "text/plain"))
        #expect(!WorkspaceVideo.isVideo(path: path, mimeType: "application/typescript"))
    }

    @Test(arguments: ["video/mp2t", "VIDEO/MP2T; charset=binary"])
    func typeScriptExtensionWithExplicitVideoMIMEIsVideo(_ mimeType: String) {
        #expect(WorkspaceVideo.isVideo(path: "capture.ts", mimeType: mimeType))
        #expect(WorkspaceVideo.isVideo(path: "capture.mts", mimeType: mimeType))
    }

    @Test(arguments: ["clip.mp4", "clip.mov", "clip.m4v", "clip.webm", "CLIP.MOV"])
    func realVideoExtensionsRemainVideo(_ path: String) {
        #expect(WorkspaceVideo.isVideo(path: path))
    }

    private static func chunk(_ data: Data, size: Int) -> [String: Any] {
        ["content": data.base64EncodedString(), "bytesRead": data.count, "size": size]
    }
}
