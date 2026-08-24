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
    }

    /// Bytes requested per `file.readChunk` call (well under the daemon's
    /// 16 MiB decoded cap; most images resolve in a single round-trip).
    static let chunkLength = 4 * 1024 * 1024
    /// Refuse to assemble files past this size — transcript images should be
    /// far smaller, and this bounds memory on a pathological path.
    static let maxFileBytes = 32 * 1024 * 1024
    /// Longest decoded edge in pixels. Decoding goes through ImageIO's
    /// downsampling thumbnail path, so a small compressed file declaring
    /// enormous pixel dimensions cannot balloon decode/render memory.
    static let maxPixelSize = 2048

    private let cache = NSCache<NSString, UIImage>()
    private var inFlight: [String: Task<UIImage, Error>] = [:]
    private let connection: ConnectionManagerRouting

    init(connection: ConnectionManagerRouting = ConnectionManager.shared) {
        self.connection = connection
    }

    /// Cached-or-fetched image for a workspace-relative file path.
    func image(workspaceId: String, path: String) async throws -> UIImage {
        let key = "\(workspaceId)\u{0}\(path)"
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<UIImage, Error> { [connection, cache] in
            let image = try await Self.fetchAndDecode(
                connection: connection, workspaceId: workspaceId, path: path)
            // Cache inside the task so an early-cancelled awaiter (view
            // scrolled away) doesn't lose the completed fetch.
            cache.setObject(image, forKey: key as NSString)
            return image
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Nonisolated async, so chunk assembly, base64 decoding, and image
    /// decode run on the global executor — only the `file.readChunk` RPC
    /// hops to the main actor. Keeps large decodes off the UI thread.
    private nonisolated static func fetchAndDecode(
        connection: ConnectionManagerRouting, workspaceId: String, path: String
    ) async throws -> UIImage {
        let data = try await fetchBytes(
            connection: connection, workspaceId: workspaceId, path: path)
        guard let image = decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    /// Assemble the file's raw bytes from sequential `file.readChunk` slices.
    private nonisolated static func fetchBytes(
        connection: ConnectionManagerRouting, workspaceId: String, path: String
    ) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            let result = try await connection.request("file.readChunk", params: [
                "workspaceId": workspaceId,
                "path": path,
                "offset": offset,
                "length": chunkLength,
            ])
            guard let dict = result as? [String: Any],
                  let content = dict["content"] as? String,
                  let bytesRead = dict["bytesRead"] as? Int,
                  let size = dict["size"] as? Int
            else { throw LoadError.malformedResponse }
            guard size <= maxFileBytes else { throw LoadError.fileTooLarge }
            guard let chunk = Data(base64Encoded: content), chunk.count == bytesRead
            else { throw LoadError.malformedResponse }
            data.append(chunk)
            offset += bytesRead
            // EOF window (bytesRead == 0) or the whole file assembled.
            if bytesRead == 0 || offset >= size { break }
        }
        return data
    }

    /// Decode via ImageIO's downsampling thumbnail path, capping the longest
    /// edge at `maxPixelSize` so decoded memory is bounded regardless of the
    /// dimensions the compressed file declares.
    private nonisolated static func decodeImage(_ data: Data) -> UIImage? {
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
