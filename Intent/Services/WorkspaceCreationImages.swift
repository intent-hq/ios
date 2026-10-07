import Foundation
import ImageIO
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Draft-owned Photos media. Videos stay on disk until the workspace exists.
@MainActor
@Observable final class WorkspaceCreationImages {
    nonisolated struct Image: Identifiable, Sendable {
        let id = UUID()
        let preview: UIImage
        let jpeg: Data

        var block: [String: Any] {
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
        }
    }

    nonisolated enum ImportError: LocalizedError {
        case requestTooLarge, tooLarge, tooMany, unreadable, unreadableVideo

        var errorDescription: String? {
            switch self {
            case .unreadable:
                return "Could not read this image. Choose a different image or try again."
            case .unreadableVideo:
                return "Could not read this video. Choose a different video or try again."
            case .tooMany:
                return "You can attach up to 5 images or videos. Remove an attachment before adding more."
            case .tooLarge:
                return "These images are too large. Choose smaller images or remove an attachment."
            case .requestTooLarge:
                return "The workspace request is too large. Remove an image or shorten the prompt and try again."
            }
        }
    }

    typealias Loader = @MainActor () async throws -> Data
    enum Media {
        case image(Data)
        case video(ImportedPhotoVideo)
    }
    typealias MediaLoader = @MainActor () async throws -> Media

    // Bound compressed source reads and prepared draft memory independently of
    // the daemon's frame limit. JSONSerialization may also escape base64 slashes.
    nonisolated static let maximumSourceBytes = 30 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    static let maximumJPEGBytes = 12 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    static let maximumRequestBytes = 39 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    nonisolated private static let maximumPixelSize = 4096
    private(set) var images: [Image] = []
    private(set) var videos: [PendingFile] = []
    private(set) var isImporting = false
    var errorMessage: String?
    @ObservationIgnored var imagePasteboard: ImagePasteboard = .general
    @ObservationIgnored private var importTask: Task<Void, Never>?

    var remainingCount: Int { Constants.Conversation.Composer.maximumImageSelectionCount - images.count - videos.count }

    func remove(_ id: UUID) {
        images.removeAll { $0.id == id }
        videos.removeAll { $0.id == id }
    }

    func addPhotos(_ items: [PhotosPickerItem]) {
        addMedia(items.map { item in
            {
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    guard let video = try await item.loadTransferable(type: ImportedPhotoVideo.self) else {
                        throw ImportError.unreadableVideo
                    }
                    return .video(video)
                }
                guard let data = try await item.loadTransferable(type: Data.self) else { throw ImportError.unreadable }
                return .image(data)
            }
        })
    }

    func addFiles(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            add(urls.map { url in { try await Self.readFile(url) } })
        case .failure(let error):
            guard (error as NSError).code != NSUserCancelledError else { return }
            errorMessage = ImportError.unreadable.localizedDescription
        }
    }

    func addPaste() {
        guard !isImporting else { return }
        let pasteboard = imagePasteboard
        let imageTypes = pasteboard.itemTypes().enumerated().compactMap { index, types in
            types.first { UTType($0)?.conforms(to: .image) == true }.map { (index, $0) }
        }
        guard !imageTypes.isEmpty else {
            errorMessage = ImportError.unreadable.localizedDescription
            return
        }
        guard imageTypes.count <= remainingCount else {
            errorMessage = ImportError.tooMany.localizedDescription
            return
        }
        // Snapshot bytes during the user's paste action, before returning to the
        // run loop. Lazy pasteboard providers can fail after that action ends or
        // the clipboard changes. Decode/downsample stays off the main actor.
        let data = imageTypes.map { index, type in
            pasteboard.data(type, index)
        }
        add(data.map { value in
            { guard let value else { throw ImportError.unreadable }; return value }
        })
    }

    /// Set the gate synchronously, before any picker/paste task can yield to Create.
    /// Each batch is atomic: a bad selection never silently drops one of its images.
    @discardableResult
    func add(_ loaders: [Loader]) -> Task<Void, Never>? {
        addMedia(loaders.map { load in { .image(try await load()) } })
    }

    @discardableResult
    func addMedia(_ loaders: [MediaLoader]) -> Task<Void, Never>? {
        guard !loaders.isEmpty, !isImporting else { return nil }
        guard loaders.count <= remainingCount else {
            errorMessage = ImportError.tooMany.localizedDescription
            return nil
        }
        errorMessage = nil
        isImporting = true
        let task = Task {
            do {
                var prepared: [Image] = []
                var preparedVideos: [PendingFile] = []
                for load in loaders {
                    let media = try await load()
                    try Task.checkCancellation()
                    switch media {
                    case let .image(data):
                        prepared.append(try await Self.prepare(data, quality: Constants.Conversation.Composer.imageCompressionQuality))
                    case let .video(video):
                        guard video.size <= ImportedPhotoVideo.maxBytes else { throw ImportedPhotoVideo.ImportError.tooLarge }
                        preparedVideos.append(PendingFile(
                            url: video.url, displayName: video.url.lastPathComponent, size: Int64(video.size), video: video
                        ))
                    }
                    try Task.checkCancellation()
                }
                guard images.reduce(0, { $0 + $1.jpeg.count }) + prepared.reduce(0, { $0 + $1.jpeg.count })
                    <= Self.maximumJPEGBytes else { throw ImportError.tooLarge }
                images.append(contentsOf: prepared)
                videos.append(contentsOf: preparedVideos)
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
            // A cancelled task may finish after a newer import has started.
            guard !Task.isCancelled else { return }
            isImporting = false
            importTask = nil
        }
        importTask = task
        return task
    }

    func cancelImport() {
        importTask?.cancel()
        importTask = nil
        isImporting = false
    }

    /// Same serializer and envelope as ConnectionManager; Int.min conservatively
    /// covers every possible numeric RPC id. Leave 1 MiB below the host's 40 MiB.
    static func validateRequest(_ params: [String: Any]) throws {
        let envelope: [String: Any] = ["jsonrpc": "2.0", "id": Int.min, "method": "workspace.create", "params": params]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        guard data.count <= maximumRequestBytes else { throw ImportError.requestTooLarge }
    }

    @concurrent
    nonisolated private static func readFile(_ url: URL) async throws -> Data {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        let values = try url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
        guard values.contentType?.conforms(to: .image) == true else { throw ImportError.unreadable }
        guard (values.fileSize ?? 0) <= maximumSourceBytes else { throw ImportError.tooLarge }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let data = try file.read(upToCount: maximumSourceBytes + 1) ?? Data()
        guard data.count <= maximumSourceBytes else { throw ImportError.tooLarge }
        return data
    }

    @concurrent
    nonisolated private static func prepare(_ data: Data, quality: CGFloat) async throws -> Image {
        guard data.count <= maximumSourceBytes else { throw ImportError.tooLarge }
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { throw ImportError.unreadable }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            throw ImportError.unreadable
        }
        let image = UIImage(cgImage: thumbnail)
        guard let jpeg = image.jpegData(compressionQuality: quality) else {
            throw ImportError.unreadable
        }
        return Image(preview: image, jpeg: jpeg)
    }
}
