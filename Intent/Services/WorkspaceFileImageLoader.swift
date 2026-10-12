import Foundation
import ImageIO
import UIKit

/// Fetches workspace-file media from the daemon via chunked `file.readChunk`
/// reads over the paired WebSocket, assembling and base64-decoding the slices
/// into an image or video poster/local file. Results are cached per (workspaceId, path) so transcript
/// scrolling never refetches, and concurrent requests for the same file share
/// one in-flight fetch.
@MainActor
final class WorkspaceFileImageLoader {
    static let shared = WorkspaceFileImageLoader()

    enum LoadError: Error, Equatable {
        case malformedResponse
        case fileTooLarge
        case notAnImage
        case notAVideo
        case notAPDF
        case pdfPasswordRequired
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

        /// One-shot `note.readAsset` read: the daemon answers the whole
        /// asset as base64 (`{ assetId, mimeType, data, sizeKb }`).
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

    /// Bytes requested per `file.readChunk` call (well under the daemon's
    /// 16 MiB decoded cap; most images resolve in a single round-trip).
    nonisolated static let chunkLength = 4 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    /// ~350 KB base64 takes ~2.8 s at 1 Mbit/s, leaving headroom under the
    /// 10-second RPC timeout on remote Tailcat links. Other media is unchanged.
    nonisolated private static let pdfChunkLength = 256 * 1024 // swiftlint:disable:this no_magic_numbers
    /// Refuse to assemble files past this size — transcript images should be
    /// far smaller, and this bounds memory on a pathological path.
    nonisolated static let maxFileBytes = 32 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    /// Longest decoded edge in pixels. Decoding goes through ImageIO's
    /// downsampling thumbnail path, so a small compressed file declaring
    /// enormous pixel dimensions cannot balloon decode/render memory.
    nonisolated static let maxPixelSize = 2048
    /// Decoded-memory budget for the cache (a 2048×2048 BGRA image is ~16 MB).
    /// Videos/PDFs charge only their preview; their temp files have a separate count bound.
    static let cacheTotalCostLimit = 64 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    /// Eight downloads bound cache-owned temp files per backend session.
    /// Attachments/viewers may retain evicted files until they release them.
    private static let cacheFileCountLimit = 8

    // NSCache requires a reference-type key; NSString preserves that Foundation contract.
    // swiftlint:disable:next legacy_objc_type
    private let cache = NSCache<NSString, WorkspaceFileMediaBox>()
    /// FIFO keys only, never extra file owners. NSCache may evict earlier, making
    /// this count conservative; stale keys cannot increase the disk bound.
    private var cachedFileKeys: [String] = []
    /// Session-lifetime negative cache: keys whose fetch/decode failed, so a
    /// persistently broken link doesn't refetch on every scroll-into-view.
    /// Intentionally uncapped (ios#264): it grows only with distinct failed
    /// links the transcript actually rendered, at ~160 B per entry measured
    /// by `SessionCacheBoundsMeasurementTests`, so even a 10k-link session
    /// retains ~1.5 MiB — noise next to one `cacheTotalCostLimit`.
    private(set) var failedKeys: Set<String> = []
    private var failedVideoKeys: Set<String> = []
    private var inFlight: [String: Task<WorkspaceFileMedia, Error>] = [:]
    private let chunkRequester: ChunkRequester
    private let diagnostics: DiagnosticStore

    init(connection: ConnectionManagerRouting = ConnectionManager.shared, diagnostics: DiagnosticStore = .shared) {
        chunkRequester = ChunkRequester(connection: connection)
        self.diagnostics = diagnostics
        cache.totalCostLimit = Self.cacheTotalCostLimit
    }

    /// Cached-or-fetched image for a workspace-relative file path.
    func image(workspaceId: String, path: String) async throws -> UIImage {
        try await cachedImage(key: Self.fileKey(workspaceId: workspaceId, path: path)) { [chunkRequester] in
            try await Self.fetchAndDecode(
                chunkRequester: chunkRequester,
                workspaceId: workspaceId,
                path: path
            )
        }
    }

    /// Cached-or-fetched image for a workspace asset id (the
    /// `note.saveAsset` / `workspace-asset://` namespace, e.g. the workspace
    /// `statusImageAssetId`). Asset ids are content-addressed, so a replaced
    /// image is a new key and refetches; keys never collide with file paths.
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

    func video(workspaceId: String, path: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        let key = "video\u{0}" + Self.fileKey(workspaceId: workspaceId, path: path)
        let media = try await cachedMedia(key: key) { [chunkRequester] in
            .video(try await Self.fetchVideo(
                chunkRequester: chunkRequester,
                workspaceId: workspaceId,
                path: path,
                mimeType: mimeType,
                limit: ImportedPhotoVideo.maxBytes
            ))
        }
        guard case .video(let video) = media else { throw LoadError.notAVideo }
        return video
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
        let media = try await cachedMedia(key: key) { .image(try await fetch()) }
        guard case .image(let image) = media else { throw LoadError.notAnImage }
        return image
    }

    private func cachedMedia(
        key: String, fetch: @escaping @Sendable () async throws -> WorkspaceFileMedia
    ) async throws -> WorkspaceFileMedia {
        // NSString is the concrete reference key required by NSCache.
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
            // Cache inside the task so an early-cancelled awaiter (view
            // scrolled away) doesn't lose the completed fetch.
            self?.store(media, forKey: key)
            return media
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
                if error as? LoadError == .notAVideo { failedVideoKeys.insert(key) }
            }
            throw error
        }
    }

    private func store(_ media: WorkspaceFileMedia, forKey key: String) {
        if media.hasTemporaryFile {
            // A refetch after memory-pressure eviction replaces its old FIFO slot.
            cachedFileKeys.removeAll { $0 == key }
            if cachedFileKeys.count >= Self.cacheFileCountLimit {
                let oldest = cachedFileKeys.removeFirst()
                // NSString is the concrete reference key required by NSCache.
                // swiftlint:disable:next legacy_objc_type
                cache.removeObject(forKey: oldest as NSString)
            }
            cachedFileKeys.append(key)
        }
        // NSString is the concrete reference key required by NSCache.
        // swiftlint:disable:next legacy_objc_type
        cache.setObject(WorkspaceFileMediaBox(media), forKey: key as NSString, cost: Self.cost(of: media))
    }

    /// Drop a key from the session negative cache so a user-initiated retry
    /// (e.g. tapping a failed attachment placeholder) actually refetches.
    func forgetFailure(workspaceId: String, path: String) {
        let key = Self.fileKey(workspaceId: workspaceId, path: path)
        failedKeys.remove(key)
        let videoKey = "video\u{0}" + key
        failedKeys.remove(videoKey)
        failedVideoKeys.remove(videoKey)
        failedKeys.remove("pdf\u{0}" + key)
    }

    /// `forgetFailure` for the asset namespace (status image retry taps).
    func forgetAssetFailure(workspaceId: String, assetId: String) {
        failedKeys.remove(Self.assetKey(workspaceId: workspaceId, assetId: assetId))
        failedVideoKeys.remove(Self.assetKey(workspaceId: workspaceId, assetId: assetId))
    }

    static func cost(of media: WorkspaceFileMedia) -> Int {
        switch media {
        case .image(let image): decodedCost(of: image)
        case .video(let video): decodedCost(of: video.poster)
        case .pdf(let pdf): decodedCost(of: pdf.thumbnail)
        }
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

    /// `fetchAndDecode` for the single-round-trip `note.readAsset` payload:
    /// only the RPC hops to the main actor; base64 and image decode run here.
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

    /// Stream videos to disk on the global executor; only one decoded chunk is
    /// held in memory. Image and saved-asset assembly keep their smaller cap.
    @concurrent
    nonisolated private static func fetchVideo(
        chunkRequester: ChunkRequester, workspaceId: String, path: String, mimeType: String?, limit: Int
    ) async throws -> WorkspaceVideo {
        let url = try WorkspaceVideo.temporaryURL(path: path, mimeType: mimeType)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let byteCount = try await writeFileBytes(
            chunkRequester: chunkRequester, workspaceId: workspaceId, path: path, to: handle, limit: limit
        )
        try handle.close()
        let video = try await WorkspaceVideo.prepare(fileURL: url, byteCount: byteCount)
        retained = true
        return video
    }

    /// Videos and PDFs share the same bounded, validated chunk-to-disk path.
    @concurrent
    nonisolated private static func writeFileBytes(
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

    /// Assemble the file's raw bytes from sequential `file.readChunk` slices
    /// on the global executor, hopping to the main actor only for each RPC.
    @concurrent
    nonisolated private static func fetchBytes(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> Data {
        var data = Data()
        var offset = 0
        while true {
            let result = try await chunkRequester.request(
                workspaceId: workspaceId,
                path: path,
                offset: offset
            )
            guard result.size <= maxFileBytes else { throw LoadError.fileTooLarge }
            guard let chunk = Data(base64Encoded: result.content), chunk.count == result.bytesRead
            else { throw LoadError.malformedResponse }
            guard data.count <= maxFileBytes - chunk.count else { throw LoadError.fileTooLarge }
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
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }
}

extension WorkspaceFileImageLoader {
    func pdf(workspaceId: String, path: String) async throws -> WorkspacePDF {
        let key = "pdf\u{0}" + Self.fileKey(workspaceId: workspaceId, path: path)
        let media = try await cachedMedia(key: key) { [chunkRequester, diagnostics] in
            let owner = DiagnosticRequestContext.Owner(operation: .pdfLoad, site: .attachmentPipeline, recording: .deferred)
            do {
                return try await DiagnosticRequestContext.$owner.withValue(owner) {
                    .pdf(try await Self.fetchPDF(chunkRequester: chunkRequester, workspaceId: workspaceId, path: path))
                }
            } catch {
                Self.recordPDFFailure(error, store: diagnostics)
                throw error
            }
        }
        guard case .pdf(let pdf) = media else { throw LoadError.notAPDF }
        return pdf
    }

    /// Closed categories only: never persist a workspace, filename, URL or
    /// foreign error description. One record per fetch, not per cached failure.
    nonisolated private static func recordPDFFailure(_ error: any Error, store: DiagnosticStore) {
        var failure = DiagnosticErrorOwnership.failure(for: error)
        var stage: DiagnosticEvent.Stage = .request
        if let error = error as? LoadError {
            let classification: DiagnosticFailure.Classification
            switch error {
            case .fileTooLarge: classification = .tooLarge
            case .malformedResponse: classification = .malformedResponse
            case .pdfPasswordRequired: classification = .passwordRequired
            case .notAPDF: classification = .unreadable
            default: classification = .unknown
            }
            stage = error == .notAPDF || error == .pdfPasswordRequired ? .decode : .response
            failure = DiagnosticFailure(origin: .localOperation, classification: classification)
        } else if failure.origin == .unknown {
            stage = .read
        }
        DiagnosticErrorOwnership.record(
            error,
            event: DiagnosticEvent(
                kind: .operationFailed,
                operation: .pdfLoad,
                site: .attachmentPipeline,
                stage: stage,
                outcome: .failed,
                failure: failure,
                effect: failure.origin == .remoteRPC ? .remoteRejected : .unknown
            ),
            store: store
        )
    }

    @concurrent
    nonisolated private static func fetchPDF(
        chunkRequester: ChunkRequester, workspaceId: String, path: String
    ) async throws -> WorkspacePDF {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chat-pdf-\(UUID()).pdf")
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try Data().write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        let byteCount = try await writeFileBytes(
            chunkRequester: chunkRequester,
            workspaceId: workspaceId,
            path: path,
            to: handle,
            limit: WorkspacePDF.maxBytes,
            length: pdfChunkLength
        )
        try handle.close()
        let pdf = try await WorkspacePDF.prepare(
            fileURL: url, name: URL(fileURLWithPath: path).lastPathComponent, byteCount: byteCount
        )
        retained = true
        return pdf
    }
}
