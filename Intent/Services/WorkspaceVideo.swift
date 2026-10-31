import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Immutable, shared ownership keeps the temporary file alive through cache eviction
/// and full-screen playback. No player is created until the user taps the poster.
nonisolated final class WorkspaceVideo: Sendable, Hashable {
    let url: URL
    let poster: UIImage
    let byteCount: Int
    /// A fixed 3× cap covers high-density transcript thumbnails without a screen lookup.
    private static let posterScale: CGFloat = 3
    private static let posterTimescale: CMTimeScale = 600
    private static let posterToleranceSeconds = 0.1
    private static let posterTime = CMTime(seconds: 0.5, preferredTimescale: posterTimescale)
    private static let posterTolerance = CMTime(seconds: posterToleranceSeconds, preferredTimescale: posterTimescale)

    private init(url: URL, poster: UIImage, byteCount: Int) {
        self.url = url
        self.poster = poster
        self.byteCount = byteCount
    }

    deinit {
        // Last release may be on MainActor. Independent utility cleanup must
        // neither inherit the UI executor nor retain the deinitializing owner.
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func == (lhs: WorkspaceVideo, rhs: WorkspaceVideo) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    static func isVideo(path: String, mimeType: String? = nil) -> Bool {
        if mimeType?.lowercased().hasPrefix("video/") == true { return true }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        // UTType maps these to MPEG transport streams; in a workspace they are
        // TypeScript sources unless the server explicitly reports video (#883).
        if typeScriptExtensions.contains(ext) { return false }
        return ext == "webm" || UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }

    private static let typeScriptExtensions: Set<String> = ["ts", "mts"]

    static func isWebM(path: String, mimeType: String? = nil) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mime = mimeType?.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces)
        return ext == "webm" || mime == "video/webm"
    }

    static func temporaryURL(path: String, mimeType: String? = nil) throws -> URL {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init)
        guard !isWebM(path: path, mimeType: mimeType) else {
            throw WorkspaceFileImageLoader.LoadError.notAVideo
        }
        let suffix = mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ext
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-video-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
    }

    @concurrent
    static func prepare(data: Data, path: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        let url = try temporaryURL(path: path, mimeType: mimeType)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return try await prepare(fileURL: url, byteCount: data.count)
    }

    /// Takes ownership of a completed temporary download, removing it on failure
    /// or when the last cache/thumbnail/player owner releases the prepared video.
    @concurrent
    static func prepare(fileURL: URL, byteCount: Int) async throws -> WorkspaceVideo {
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: fileURL) } }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: fileURL)
        guard try await asset.load(.isPlayable) else {
            throw WorkspaceFileImageLoader.LoadError.notAVideo
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let posterSide = SquareImageThumbnail.transcriptSide * posterScale
        generator.maximumSize = CGSize(
            width: posterSide,
            height: posterSide
        )
        generator.requestedTimeToleranceBefore = posterTolerance
        generator.requestedTimeToleranceAfter = posterTolerance
        let duration = try await asset.load(.duration)
        let frame = try await generator.image(at: duration > posterTime ? posterTime : .zero)
        try Task.checkCancellation()
        let video = WorkspaceVideo(url: fileURL, poster: UIImage(cgImage: frame.image), byteCount: byteCount)
        retained = true
        return video
    }
}

nonisolated enum WorkspaceFileMedia: Sendable {
    case image(UIImage)
    case pdf(WorkspacePDF)
    case text(WorkspaceTextFile)
    case video(WorkspaceVideo)

    var hasTemporaryFile: Bool {
        switch self {
        case .image: false
        case .video, .pdf, .text: true
        }
    }
}

/// NSCache's value must be a reference type.
nonisolated final class WorkspaceFileMediaBox {
    let media: WorkspaceFileMedia

    init(_ media: WorkspaceFileMedia) { self.media = media }
}
