import AVFoundation
import CoreTransferable
import UIKit
import UniformTypeIdentifiers

/// Owns a disk-backed Photos export. Composer selections and send attempts share
/// this owner so removing a preview cannot delete a file still being uploaded.
nonisolated final class ImportedPhotoVideo: Transferable, Sendable, Equatable {
    // Shared composer/transcript policy; all other files retain the 1 GiB cap.
    static let maxBytes = 200 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers

    enum ImportError: LocalizedError, Equatable {
        case tooLarge

        var errorDescription: String? { "Video is too large to send (max 200 MB)." }
    }

    let url: URL
    let size: Int
    let poster: UIImage?
    private static let posterSide: CGFloat = 240

    private init(url: URL, size: Int, poster: UIImage?) {
        self.url = url
        self.size = size
        self.poster = poster
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in
            try await importFile(at: received.file)
        }
    }

    static func == (lhs: ImportedPhotoVideo, rhs: ImportedPhotoVideo) -> Bool { lhs === rhs }

    deinit {
        let directory = url.deletingLastPathComponent()
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// Copy before the Photos transfer callback returns: its source URL is only
    /// valid inside that callback. Neither copying nor poster creation reads the
    /// whole movie into Data, and both run off the UI actor.
    @concurrent
    static func importFile(at source: URL) async throws -> ImportedPhotoVideo {
        try Task.checkCancellation()
        let values = try source.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else { throw AttachmentUploadService.UploadError.unreadableFile }
        guard size <= maxBytes else { throw ImportError.tooLarge }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("photos-video-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        var retained = false
        defer { if !retained { try? FileManager.default.removeItem(at: directory) } }
        let url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        try Task.checkCancellation()
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: posterSide, height: posterSide)
        let frame = try? await generator.image(at: .zero)
        try Task.checkCancellation()
        let video = ImportedPhotoVideo(url: url, size: size, poster: frame.map { UIImage(cgImage: $0.image) })
        retained = true
        return video
    }
}
