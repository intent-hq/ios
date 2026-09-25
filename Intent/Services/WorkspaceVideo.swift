import AVFoundation
import UIKit
import UniformTypeIdentifiers

/// Immutable, shared ownership keeps the temporary file alive through cache eviction
/// and full-screen playback. No player is created until the user taps the poster.
nonisolated final class WorkspaceVideo: Sendable, Hashable {
    let url: URL
    let poster: UIImage
    let byteCount: Int

    private init(url: URL, poster: UIImage, byteCount: Int) {
        self.url = url
        self.poster = poster
        self.byteCount = byteCount
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    static func == (lhs: WorkspaceVideo, rhs: WorkspaceVideo) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    static func isVideo(path: String, mimeType: String? = nil) -> Bool {
        if mimeType?.lowercased().hasPrefix("video/") == true { return true }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ext == "webm" || UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }

    @concurrent
    static func prepare(data: Data, path: String, mimeType: String? = nil) async throws -> WorkspaceVideo {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        let mime = mimeType?.lowercased().split(separator: ";").first.map(String.init)
        guard ext != "webm", mime != "video/webm" else {
            throw WorkspaceFileImageLoader.LoadError.notAVideo
        }
        let suffix = mime.flatMap { UTType(mimeType: $0)?.preferredFilenameExtension } ?? ext
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-video-\(UUID().uuidString)")
            .appendingPathExtension(suffix)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: url) } }
        try data.write(to: url, options: .atomic)
        let asset = AVURLAsset(url: url)
        guard try await asset.load(.isPlayable) else {
            throw WorkspaceFileImageLoader.LoadError.notAVideo
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(
            width: WorkspaceFileImageLoader.maxPixelSize,
            height: WorkspaceFileImageLoader.maxPixelSize
        )
        let frame = try await generator.image(at: .zero)
        try Task.checkCancellation()
        let video = WorkspaceVideo(url: url, poster: UIImage(cgImage: frame.image), byteCount: data.count)
        retained = true
        return video
    }
}

nonisolated enum WorkspaceFileMedia: Sendable {
    case image(UIImage)
    case video(WorkspaceVideo)
}

/// NSCache's value must be a reference type.
nonisolated final class WorkspaceFileMediaBox {
    let media: WorkspaceFileMedia

    init(_ media: WorkspaceFileMedia) { self.media = media }
}
