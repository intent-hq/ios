import Foundation
import ImageIO
import UIKit

@MainActor
final class WorkspaceFileImageLoader {
    static let shared = WorkspaceFileImageLoader()

    enum LoadError: Error, Equatable {
        case malformedResponse
        case fileTooLarge
        case notAnImage
        case notAVideo
        case notAPDF
        case notUTF8Text
        case pdfPasswordRequired
        case previouslyFailed
    }

    struct FileChunk: Sendable {
        let content: String
        let bytesRead: Int
        let size: Int
    }

    @MainActor
    final class ChunkRequester {
        let connection: ConnectionManagerRouting

        init(connection: ConnectionManagerRouting) {
            self.connection = connection
        }

        func request(
            workspaceId: String, path: String, offset: Int, length: Int = WorkspaceFileImageLoader.chunkLength
        ) async throws -> FileChunk {
            let result = try await connection.request("file.readChunk", params: [
                "workspaceId": workspaceId,
                "path": path,
                "offset": offset,
                "length": length
            ])
            guard let dict = result as? [String: Any],
                  let content = dict["content"] as? String,
                  let bytesRead = dict["bytesRead"] as? Int,
                  let size = dict["size"] as? Int
            else { throw LoadError.malformedResponse }
            return FileChunk(content: content, bytesRead: bytesRead, size: size)
        }

        func requestAsset(workspaceId: String, assetId: String) async throws -> (data: String, mimeType: String?) {
            let result = try await connection.request("note.readAsset", params: [
                "workspaceId": workspaceId,
                "asset": assetId
            ])
            guard let dict = result as? [String: Any],
                  let data = dict["data"] as? String
            else { throw LoadError.malformedResponse }
            return (data, dict["mimeType"] as? String)
        }
    }

    // Keep MiB conversions visible in the named transfer and decoded-memory limits.
    // swiftlint:disable no_magic_numbers
    nonisolated static let chunkLength = 4 * 1024 * 1024
    nonisolated static let pdfChunkLength = 256 * 1024
    nonisolated static let maxFileBytes = 32 * 1024 * 1024
    nonisolated static let maxPixelSize = 2048
    static let cacheTotalCostLimit = 64 * 1024 * 1024
    // swiftlint:enable no_magic_numbers
    private static let cacheFileCountLimit = 8

    // swiftlint:disable:next legacy_objc_type
    private let cache = NSCache<NSString, WorkspaceFileMediaBox>()
    private var cachedFileKeys: [String] = []
    private(set) var failedKeys: Set<String> = []
    private var failedVideoKeys: Set<String> = []
    private var inFlight: [String: Task<WorkspaceFileMedia, Error>] = [:]
    let chunkRequester: ChunkRequester
    let diagnostics: DiagnosticStore

    init(connection: ConnectionManagerRouting = ConnectionManager.shared, diagnostics: DiagnosticStore = .shared) {
        chunkRequester = ChunkRequester(connection: connection)
        self.diagnostics = diagnostics
        cache.totalCostLimit = Self.cacheTotalCostLimit
    }

    func image(workspaceId: String, path: String) async throws -> UIImage {
        try await cachedImage(key: Self.fileKey(workspaceId: workspaceId, path: path)) { [chunkRequester] in
            try await Self.fetchAndDecode(
                chunkRequester: chunkRequester,
                workspaceId: workspaceId,
                path: path
            )
        }
    }

    func assetImage(workspaceId: String, assetId: String) async throws -> UIImage {
        guard case .image(let image) = try await assetMedia(workspaceId: workspaceId, assetId: assetId) else {
            throw LoadError.notAnImage
        }
        return image
    }

    func assetMedia(workspaceId: String, assetId: String) async throws -> WorkspaceFileMedia {
        try await cachedMedia(key: Self.assetKey(workspaceId: workspaceId, assetId: assetId)) { [chunkRequester] in
            try await Self.fetchAndDecodeAsset(
                chunkRequester: chunkRequester,
                workspaceId: workspaceId,
                assetId: assetId
            )
        }
    }

    static func fileKey(workspaceId: String, path: String) -> String {
        "\(workspaceId)\u{0}\(path)"
    }

    private static func assetKey(workspaceId: String, assetId: String) -> String {
        "asset\u{0}\(workspaceId)\u{0}\(assetId)"
    }

    private func cachedImage(
        key: String, fetch: @escaping @Sendable () async throws -> UIImage
    ) async throws -> UIImage {
        let media = try await cachedMedia(key: key) { .image(try await fetch()) }
        guard case .image(let image) = media else { throw LoadError.notAnImage }
        return image
    }

    func cachedMedia(
        key: String, fetch: @escaping @Sendable () async throws -> WorkspaceFileMedia
    ) async throws -> WorkspaceFileMedia {
        // swiftlint:disable:next legacy_objc_type
        if let cached = cache.object(forKey: key as NSString) {
            return cached.media
        }
        if failedVideoKeys.contains(key) { throw LoadError.notAVideo }
        if failedKeys.contains(key) {
            throw LoadError.previouslyFailed
        }
        if let task = inFlight[key] {
            return try await task.value
        }
        let task = Task<WorkspaceFileMedia, Error> { [weak self] in
            let media = try await fetch()
            self?.store(media, forKey: key)
            return media
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            return try await task.value
        } catch {
            if Self.shouldNegativelyCache(error) {
                failedKeys.insert(key)
                if error as? LoadError == .notAVideo { failedVideoKeys.insert(key) }
            }
            throw error
        }
    }

    static func shouldNegativelyCache(_ error: any Error) -> Bool {
        !(error is CancellationError) && !DiagnosticErrorOwnership.isConnectionLoss(error)
    }

    private func store(_ media: WorkspaceFileMedia, forKey key: String) {
        if media.hasTemporaryFile {
            cachedFileKeys.removeAll { $0 == key }
            if cachedFileKeys.count >= Self.cacheFileCountLimit {
                let oldest = cachedFileKeys.removeFirst()
                // swiftlint:disable:next legacy_objc_type
                cache.removeObject(forKey: oldest as NSString)
            }
            cachedFileKeys.append(key)
        }
        // swiftlint:disable:next legacy_objc_type
        cache.setObject(WorkspaceFileMediaBox(media), forKey: key as NSString, cost: Self.cost(of: media))
    }

    func forgetFailure(workspaceId: String, path: String) {
        let key = Self.fileKey(workspaceId: workspaceId, path: path)
        failedKeys.remove(key)
        let videoKey = "video\u{0}" + key
        failedKeys.remove(videoKey)
        failedVideoKeys.remove(videoKey)
        failedKeys.remove("pdf\u{0}" + key)
        failedKeys.remove("text\u{0}" + key)
    }

    func forgetAssetFailure(workspaceId: String, assetId: String) {
        failedKeys.remove(Self.assetKey(workspaceId: workspaceId, assetId: assetId))
        failedVideoKeys.remove(Self.assetKey(workspaceId: workspaceId, assetId: assetId))
    }

    static func decodedCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        return cgImage.bytesPerRow * cgImage.height
    }

    @concurrent
    nonisolated private static func fetchAndDecode(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> UIImage {
        let data = try await fetchBytes(
            chunkRequester: chunkRequester,
            workspaceId: workspaceId,
            path: path
        )
        guard let image = decodeImage(data) else {
            throw LoadError.notAnImage
        }
        return image
    }

    @concurrent
    nonisolated private static func fetchAndDecodeAsset(
        chunkRequester: ChunkRequester, workspaceId: String, assetId: String
    ) async throws -> WorkspaceFileMedia {
        let response = try await chunkRequester.requestAsset(workspaceId: workspaceId, assetId: assetId)
        let isVideo = WorkspaceVideo.isVideo(path: assetId, mimeType: response.mimeType)
        do {
            guard let data = Data(base64Encoded: response.data) else { throw LoadError.malformedResponse }
            guard data.count <= maxFileBytes else { throw LoadError.fileTooLarge }
            if isVideo {
                return .video(try await WorkspaceVideo.prepare(data: data, path: assetId, mimeType: response.mimeType))
            }
            guard let image = decodeImage(data) else { throw LoadError.notAnImage }
            return .image(image)
        } catch {
            if isVideo, !(error is CancellationError) { throw LoadError.notAVideo }
            throw error
        }
    }

    @concurrent
    nonisolated static func writeFileBytes(
        chunkRequester: ChunkRequester,
        workspaceId: String,
        path: String,
        to handle: FileHandle,
        limit: Int,
        length: Int = chunkLength
    ) async throws -> Int {
        var offset = 0
        var expectedSize: Int?
        while true {
            try Task.checkCancellation()
            let result = try await chunkRequester.request(workspaceId: workspaceId, path: path, offset: offset, length: length)
            try Task.checkCancellation()
            guard result.size <= limit else { throw LoadError.fileTooLarge }
            guard result.size >= 0, result.bytesRead >= 0, result.bytesRead <= length,
                  expectedSize == nil || expectedSize == result.size,
                  let chunk = Data(base64Encoded: result.content), chunk.count == result.bytesRead,
                  offset <= result.size, chunk.count <= result.size - offset
            else { throw LoadError.malformedResponse }
            expectedSize = result.size
            try handle.write(contentsOf: chunk)
            offset += chunk.count
            if offset == result.size { return offset }
            guard !chunk.isEmpty else { throw LoadError.malformedResponse }
        }
    }

    @concurrent
    nonisolated static func fetchBytes(
        chunkRequester: ChunkRequester,
        workspaceId: String,
        path: String,
        limit: Int = maxFileBytes,
        length: Int = chunkLength
    ) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            try Task.checkCancellation()
            let result = try await chunkRequester.request(
                workspaceId: workspaceId,
                path: path,
                offset: offset,
                length: length
            )
            guard result.size <= limit else { throw LoadError.fileTooLarge }
            guard let chunk = Data(base64Encoded: result.content), chunk.count == result.bytesRead
            else { throw LoadError.malformedResponse }
            guard data.count <= limit - chunk.count else { throw LoadError.fileTooLarge }
            data.append(chunk)
            offset += result.bytesRead
            if result.bytesRead == 0 || offset >= result.size { break }
        }
        return data
    }

    nonisolated static func decodeImage(_ data: Data) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
            return nil
        }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}
