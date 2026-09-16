import Foundation
import ImageIO
import UIKit

/// Fetches workspace-file images from the daemon via chunked `file.readChunk`
/// reads over the paired WebSocket, assembling and base64-decoding the slices
/// into a `UIImage`. Results are cached per (workspaceId, path) so transcript
/// scrolling never refetches, and concurrent requests for the same file share
/// one in-flight fetch.
@MainActor
final class WorkspaceFileImageLoader {
    static let shared = WorkspaceFileImageLoader()

    enum LoadError: Error, Equatable {
        case malformedResponse
        case fileTooLarge
        case notAnImage
        case previouslyFailed
    }

    private struct FileChunk: Sendable {
        let content: String
        let bytesRead: Int
        let size: Int
    }

    @MainActor
    private final class ChunkRequester {
        let connection: ConnectionManagerRouting

        init(connection: ConnectionManagerRouting) {
            self.connection = connection
        }

        func request(workspaceId: String, path: String, offset: Int) async throws -> FileChunk {
            let result = try await connection.request("file.readChunk", params: [
                "workspaceId": workspaceId,
                "path": path,
                "offset": offset,
                "length": WorkspaceFileImageLoader.chunkLength,
            ])
            guard let dict = result as? [String: Any],
                  let content = dict["content"] as? String,
                  let bytesRead = dict["bytesRead"] as? Int,
                  let size = dict["size"] as? Int
            else { throw LoadError.malformedResponse }
            return FileChunk(content: content, bytesRead: bytesRead, size: size)
        }

        /// One-shot `note.readAsset` read: the daemon answers the whole
        /// asset as base64 (`{ assetId, mimeType, data, sizeKb }`).
        func requestAsset(workspaceId: String, assetId: String) async throws -> String {
            let result = try await connection.request("note.readAsset", params: [
                "workspaceId": workspaceId,
                "asset": assetId,
            ])
            guard let dict = result as? [String: Any],
                  let data = dict["data"] as? String
            else { throw LoadError.malformedResponse }
            return data
        }
    }

    /// Bytes requested per `file.readChunk` call (well under the daemon's
    /// 16 MiB decoded cap; most images resolve in a single round-trip).
    static let chunkLength = 4 * 1024 * 1024
    /// Refuse to assemble files past this size — transcript images should be
    /// far smaller, and this bounds memory on a pathological path.
    nonisolated static let maxFileBytes = 32 * 1024 * 1024
    /// Longest decoded edge in pixels. Decoding goes through ImageIO's
    /// downsampling thumbnail path, so a small compressed file declaring
    /// enormous pixel dimensions cannot balloon decode/render memory.
    nonisolated static let maxPixelSize = 2048
    /// Total decoded-byte budget for the image cache (a 2048×2048 BGRA image
    /// is ~16 MB, so this holds a handful before NSCache evicts).
    static let cacheTotalCostLimit = 64 * 1024 * 1024

    private let cache = NSCache<NSString, UIImage>()
    /// Session-lifetime negative cache: keys whose fetch/decode failed, so a
    /// persistently broken link doesn't refetch on every scroll-into-view.
    /// Intentionally uncapped (ios#264): it grows only with distinct failed
    /// links the transcript actually rendered, at ~160 B per entry measured
    /// by `SessionCacheBoundsMeasurementTests`, so even a 10k-link session
    /// retains ~1.5 MiB — noise next to one `cacheTotalCostLimit`.
    private(set) var failedKeys: Set<String> = []
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let chunkRequester: ChunkRequester

    init(connection: ConnectionManagerRouting = ConnectionManager.shared) {
        chunkRequester = ChunkRequester(connection: connection)
        cache.totalCostLimit = Self.cacheTotalCostLimit
    }

    /// Cached-or-fetched image for a workspace-relative file path.
    func image(workspaceId: String, path: String) async throws -> UIImage {
        try await cachedImage(key: Self.fileKey(workspaceId: workspaceId, path: path)) {
            [chunkRequester] in
            try await Self.fetchAndDecode(
                chunkRequester: chunkRequester, workspaceId: workspaceId, path: path)
        }
    }

    /// Cached-or-fetched image for a workspace asset id (the
    /// `note.saveAsset` / `workspace-asset://` namespace, e.g. the workspace
    /// `statusImageAssetId`). Asset ids are content-addressed, so a replaced
    /// image is a new key and refetches; keys never collide with file paths.
    func assetImage(workspaceId: String, assetId: String) async throws -> UIImage {
        try await cachedImage(key: Self.assetKey(workspaceId: workspaceId, assetId: assetId)) {
            [chunkRequester] in
            try await Self.fetchAndDecodeAsset(
                chunkRequester: chunkRequester, workspaceId: workspaceId, assetId: assetId)
        }
    }

    private static func fileKey(workspaceId: String, path: String) -> String {
        "\(workspaceId)\u{0}\(path)"
    }

    private static func assetKey(workspaceId: String, assetId: String) -> String {
        "asset\u{0}\(workspaceId)\u{0}\(assetId)"
    }

    private func cachedImage(
        key: String, fetch: @escaping @Sendable () async throws -> UIImage
    ) async throws -> UIImage {
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if failedKeys.contains(key) {
            throw LoadError.previouslyFailed
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<UIImage, Error> { [cache] in
            let image = try await fetch()
            // Cache inside the task so an early-cancelled awaiter (view
            // scrolled away) doesn't lose the completed fetch.
            cache.setObject(image, forKey: key as NSString, cost: Self.decodedCost(of: image))
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            return try await task.value
        } catch {
            // Remember the failure for the session (skip cancellation — the
            // fetch itself didn't fail) so broken links don't refetch forever.
            if !(error is CancellationError) {
                failedKeys.insert(key)
            }
            throw error
        }
    }

    /// Drop a key from the session negative cache so a user-initiated retry
    /// (e.g. tapping a failed attachment placeholder) actually refetches.
    func forgetFailure(workspaceId: String, path: String) {
        failedKeys.remove(Self.fileKey(workspaceId: workspaceId, path: path))
    }

    /// `forgetFailure` for the asset namespace (status image retry taps).
    func forgetAssetFailure(workspaceId: String, assetId: String) {
        failedKeys.remove(Self.assetKey(workspaceId: workspaceId, assetId: assetId))
    }

    /// Approximate decoded byte size, used as the NSCache cost (shared with
    /// `RemoteImageLoader`).
    static func decodedCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    /// Explicitly concurrent so chunk assembly, base64 decoding, and image
    /// decode run on the global executor — only each `file.readChunk` RPC
    /// hops to the main actor. Keeps large decodes off the UI thread.
    @concurrent
    private nonisolated static func fetchAndDecode(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> UIImage {
        let data = try await fetchBytes(
            chunkRequester: chunkRequester, workspaceId: workspaceId, path: path)
        guard let image = decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    /// `fetchAndDecode` for the single-round-trip `note.readAsset` payload:
    /// only the RPC hops to the main actor; base64 and image decode run here.
    @concurrent
    private nonisolated static func fetchAndDecodeAsset(
        chunkRequester: ChunkRequester, workspaceId: String, assetId: String
    ) async throws -> UIImage {
        let base64 = try await chunkRequester.requestAsset(workspaceId: workspaceId, assetId: assetId)
        guard let data = Data(base64Encoded: base64) else {
            throw LoadError.malformedResponse
        }
        guard data.count <= maxFileBytes else { throw LoadError.fileTooLarge }
        guard let image = decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    /// Assemble the file's raw bytes from sequential `file.readChunk` slices
    /// on the global executor, hopping to the main actor only for each RPC.
    @concurrent
    private nonisolated static func fetchBytes(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            let result = try await chunkRequester.request(
                workspaceId: workspaceId, path: path, offset: offset)
            guard result.size <= maxFileBytes else { throw LoadError.fileTooLarge }
            guard let chunk = Data(base64Encoded: result.content), chunk.count == result.bytesRead
            else { throw LoadError.malformedResponse }
            data.append(chunk)
            offset += result.bytesRead
            // EOF window (bytesRead == 0) or the whole file assembled.
            if result.bytesRead == 0 || offset >= result.size { break }
        }
        return data
    }

    /// Decode via ImageIO's downsampling thumbnail path, capping the longest
    /// edge at `maxPixelSize` so decoded memory is bounded regardless of the
    /// dimensions the compressed file declares (shared with
    /// `RemoteImageLoader`).
    nonisolated static func decodeImage(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
