import AVFoundation
import Foundation
@testable import Intent
import Testing
import Textual
import UIKit

/// Real media bytes exercise routing, daemon transport, poster decoding and tap
/// dispatch together. Existing image/remote suites remain the image contract owners.
@MainActor
struct IntentFileVideoTests {
    @Test(arguments: ["mp4", "mov", "m4v"])
    func fileVideoProducesPlayablePoster(_ ext: String) async throws {
        let bytes = try await Self.videoBytes()
        let connection = FakeConnectionManager()
        let midpoint = bytes.count / 2
        connection.responseQueueMap["file.readChunk"] = [
            Self.chunk(Data(bytes.prefix(midpoint)), size: bytes.count),
            Self.chunk(Data(bytes.suffix(from: midpoint)), size: bytes.count)
        ]
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: "current", fallback: .image())
        loader.fileVideo = { workspaceId, path in
            try await fileLoader.video(workspaceId: workspaceId, path: path)
        }
        let prefix = ext == "mp4" ? "intent://local/file/" : "intent://local/linked/file/"
        let url = try #require(URL(string: prefix + ".intent/launch-logo-100pt/launch-gradient." + ext))
        let attachment = try await loader.resolvedAttachment(for: url, text: "", fallback: forbiddenFallback)
        let video = try #require(MarkdownTextView.playbackVideo(for: attachment))
        #expect(video.poster.size.width == 16)
        #expect(try Data(contentsOf: video.url) == bytes)
        #expect(MarkdownTextView.lightboxImage(for: attachment) == nil)
        #expect(try await AVURLAsset(url: video.url).load(.isPlayable))
        let cached = try await loader.resolvedAttachment(for: url, text: "", fallback: forbiddenFallback)
        #expect(MarkdownTextView.playbackVideo(for: cached) === video)
        let requests = connection.paramsForMethod("file.readChunk")
        #expect(requests.count == 2)
        #expect(requests.first?["workspaceId"] as? String == (ext == "mp4" ? "current" : "linked"))
        #expect(requests.last?["offset"] as? Int == midpoint)
    }

    @Test func savedVideoUsesMIMEWithoutFileExtension() async throws {
        let bytes = try await Self.videoBytes()
        let connection = FakeConnectionManager()
        connection.responseMap["note.readAsset"] = ["data": bytes.base64EncodedString(), "mimeType": "video/mp4"]
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: "current", fallback: .image())
        loader.assetMedia = { workspaceId, assetId in
            try await fileLoader.assetMedia(workspaceId: workspaceId, assetId: assetId)
        }
        let url = try #require(URL(string: "workspace-asset://linked/asset-id?backend=other"))
        let attachment = try await loader.resolvedAttachment(for: url, text: "Clip", fallback: forbiddenFallback)
        let video = try #require(MarkdownTextView.playbackVideo(for: attachment))
        #expect(video.poster.size.width == 16)
        #expect(try Data(contentsOf: video.url) == bytes)
        #expect(connection.paramsForMethod("note.readAsset").first?["workspaceId"] as? String == "linked")
        #expect(connection.paramsForMethod("file.readChunk").isEmpty)
    }

    @Test(arguments: ["webm", "missing", "corrupt", "oversized", "no-workspace"])
    func unavailableFileVideoIsLabelledVideo(_ failure: String) async throws {
        let connection = FakeConnectionManager()
        if failure == "missing" {
            connection.errorMap["file.readChunk"] = URLError(.fileDoesNotExist)
        } else {
            connection.responseMap["file.readChunk"] = Self.chunk(Data([0]), size:
                failure == "oversized" ? WorkspaceFileImageLoader.maxFileBytes + 1 : 1)
        }
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: failure == "no-workspace" ? nil : "ws", fallback: .image())
        loader.fileVideo = { workspaceId, path in
            try await fileLoader.video(workspaceId: workspaceId, path: path)
        }
        let name = failure == "webm" ? "clip.webm" : "clip.mp4"
        let url = try #require(URL(string: "intent://local/file/" + name))
        let attachment = try await loader.resolvedAttachment(for: url, text: "", fallback: forbiddenFallback)
        let placeholder = try #require(attachment.base as? IntentFileVideoFailureAttachment)
        #expect(placeholder.description == "Video: \(name)")
        #expect(MarkdownTextView.playbackVideo(for: attachment) == nil)
        #expect(MarkdownTextView.lightboxImage(for: attachment) == nil)
    }

    @Test(arguments: ["video/webm", "video/mp4"])
    func failedVideoAssetStaysLabelledVideoAfterNegativeCaching(_ mime: String) async throws {
        let connection = FakeConnectionManager()
        connection.responseMap["note.readAsset"] = ["data": "AA==", "mimeType": mime]
        let fileLoader = WorkspaceFileImageLoader(connection: connection)
        var loader = IntentFileAttachmentLoader(workspaceId: nil, fallback: .image())
        loader.assetMedia = { workspaceId, assetId in
            try await fileLoader.assetMedia(workspaceId: workspaceId, assetId: assetId)
        }
        let url = try #require(URL(string: "workspace-asset://ws/opaque-id"))
        for _ in 0..<2 {
            let attachment = try await loader.resolvedAttachment(for: url, text: "", fallback: forbiddenFallback)
            #expect((attachment.base as? IntentFileVideoFailureAttachment)?.description == "Video: opaque-id")
        }
        #expect(connection.paramsForMethod("note.readAsset").count == 1)
    }

    private func forbiddenFallback() async -> AnyAttachment {
        Issue.record("Workspace video must not reach the network fallback")
        return AnyAttachment(IntentFileFailureAttachment(altText: "unexpected fallback"))
    }

    @Test func temporaryVideoIsRemovedWhenLastOwnerReleasesIt() async throws {
        let bytes = try await Self.videoBytes()
        var video: WorkspaceVideo? = try await WorkspaceVideo.prepare(data: bytes, path: "clip.mp4")
        let url = try #require(video?.url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        video = nil
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private static func chunk(_ data: Data, size: Int) -> [String: Any] {
        ["content": data.base64EncodedString(), "bytesRead": data.count, "size": size]
    }

    /// A single deterministic H.264 frame; no network or checked-in binary fixture.
    private static func videoBytes() async throws -> Data {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("video-test-\(UUID()).mp4")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 16, AVVideoHeightKey: 16
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        let pool = try #require(adaptor.pixelBufferPool)
        #expect(CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer) == kCVReturnSuccess)
        let frame = try #require(buffer)
        CVPixelBufferLockBaseAddress(frame, [])
        if let base = CVPixelBufferGetBaseAddress(frame) {
            memset(base, 0x7F, CVPixelBufferGetDataSize(frame))
        }
        CVPixelBufferUnlockBaseAddress(frame, [])
        #expect(adaptor.append(frame, withPresentationTime: .zero))
        writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 30))
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return try Data(contentsOf: url)
    }
}
