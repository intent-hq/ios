import AVFoundation
import UIKit
import UniformTypeIdentifiers

nonisolated final class WorkspaceVideo: Sendable, Hashable {
    let url: URL
    let poster: UIImage
    let byteCount: Int
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
        Task.detached(priority: .utility) { [url] in
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: Self.shareDirectory(for: url))
        }
    }

    private static let fallbackExportBase = "Video"
    private static let maxExportBaseLength = 200

    static func exportFileName(for name: String, pathExtension: String) -> String {
        let unsafe = CharacterSet(charactersIn: "/:\\").union(.controlCharacters).union(.newlines)
        var base = String(String.UnicodeScalarView(name.unicodeScalars.map { unsafe.contains($0) ? "-" : $0 }))
            .trimmingCharacters(in: .whitespaces)
        while base.hasPrefix(".") { base.removeFirst() }
        if let dot = base.lastIndex(of: "."),
           UTType(filenameExtension: String(base[base.index(after: dot)...]))?.conforms(to: .movie) == true {
            base = String(base[..<dot])
        }
        base = String(base.prefix(maxExportBaseLength)).trimmingCharacters(in: .whitespaces)
        if base.isEmpty { base = fallbackExportBase }
        return pathExtension.isEmpty ? base : base + "." + pathExtension
    }

    static func shareDirectory(for url: URL) -> URL {
        url.deletingLastPathComponent()
            .appendingPathComponent(url.deletingPathExtension().lastPathComponent + "-share", isDirectory: true)
    }

    func shareFile(named name: String) throws -> URL {
        let directory = Self.shareDirectory(for: url)
        let target = directory.appendingPathComponent(
            Self.exportFileName(for: name, pathExtension: url.pathExtension),
            isDirectory: false
        )
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: target.path) { return target }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try fileManager.linkItem(at: url, to: target)
        } catch {
            try fileManager.copyItem(at: url, to: target)
        }
        return target
    }

    static func == (lhs: WorkspaceVideo, rhs: WorkspaceVideo) -> Bool { lhs === rhs }

    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }

    static func isVideo(path: String, mimeType: String? = nil) -> Bool {
        if mimeType?.lowercased().hasPrefix("video/") == true { return true }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
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
    case document(WorkspaceDocument)
    case image(UIImage)
    case pdf(WorkspacePDF)
    case text(WorkspaceTextFile)
    case video(WorkspaceVideo)

    var hasTemporaryFile: Bool {
        switch self {
        case .image: false
        case .document, .video, .pdf, .text: true
        }
    }
}

nonisolated final class WorkspaceFileMediaBox {
    let media: WorkspaceFileMedia

    init(_ media: WorkspaceFileMedia) { self.media = media }
}
