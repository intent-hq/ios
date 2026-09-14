import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Main-actor-owned composer attachment state and send-time placement logic.
/// Security-scoped access begins when a file is added and remains held until
/// removal, clear after a successful send/queue, or deinitialization.
@MainActor
@Observable final class ConversationAttachmentPipeline {
    static let maxImageReferenceBytes = 30 * 1024 * 1024

    enum ImagePlacementError: LocalizedError {
        case encodingFailed(index: Int)
        case imageTooLarge(index: Int)
        case imagesTooLarge
        case placementFailed(index: Int, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .encodingFailed(index):
                return "Image \(index) could not be encoded for sending."
            case let .imageTooLarge(index):
                return "Image \(index) is too large to send (over 30 MiB as JPEG)."
            case .imagesTooLarge:
                return "The attached images are too large to send together (over 30 MiB total as JPEG)."
            case let .placementFailed(index, underlying):
                return "Image \(index) could not be uploaded. \(underlying.localizedDescription)"
            }
        }
    }

    enum FilePlacementError: LocalizedError {
        case fileTooLarge(name: String)
        case placementFailed(name: String, underlying: Error)

        var errorDescription: String? {
            switch self {
            case let .fileTooLarge(name):
                return "\"\(name)\" is too large to send (over 1 GiB)."
            case let .placementFailed(name, underlying):
                return "\"\(name)\" could not be uploaded. \(underlying.localizedDescription)"
            }
        }
    }

    var pendingImages: [UIImage] = []
    var selectedPhotoItems: [PhotosPickerItem] = []
    var pendingFiles: [PendingFile] = []
    var fileUploadProgress: [UUID: Double] = [:]
    var imagePlacementError: String?
    var filePlacementError: String?

    var hasPendingAttachments: Bool { !pendingImages.isEmpty || !pendingFiles.isEmpty }
    var isUploadingFiles: Bool { !fileUploadProgress.isEmpty }

    @ObservationIgnored var uploadService: AttachmentUploadService
    @ObservationIgnored private var securityScopedURLs: [URL] = []
    @ObservationIgnored private let startSecurityScopedAccess: @Sendable (URL) -> Bool
    @ObservationIgnored private let stopSecurityScopedAccess: @Sendable (URL) -> Void

    init(
        uploadService: AttachmentUploadService = .shared,
        startSecurityScopedAccess: @escaping @Sendable (URL) -> Bool = { url in
            url.startAccessingSecurityScopedResource()
        },
        stopSecurityScopedAccess: @escaping @Sendable (URL) -> Void = { url in
            url.stopAccessingSecurityScopedResource()
        }
    ) {
        self.uploadService = uploadService
        self.startSecurityScopedAccess = startSecurityScopedAccess
        self.stopSecurityScopedAccess = stopSecurityScopedAccess
    }

    deinit {
        for url in securityScopedURLs {
            stopSecurityScopedAccess(url)
        }
    }

    func addImage(_ image: UIImage) { pendingImages.append(image) }

    func removeImage(at index: Int) {
        guard pendingImages.indices.contains(index) else { return }
        pendingImages.remove(at: index)
    }

    func loadSelectedPhotos() async {
        for item in selectedPhotoItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data) {
                pendingImages.append(image)
            }
        }
        selectedPhotoItems.removeAll()
    }

    func addFiles(_ urls: [URL]) {
        for url in urls {
            guard !pendingFiles.contains(where: { $0.url == url }) else { continue }
            if startSecurityScopedAccess(url) { securityScopedURLs.append(url) }
            let values = try? url.resourceValues(forKeys: [.nameKey, .fileSizeKey])
            pendingFiles.append(PendingFile(
                url: url,
                displayName: values?.name ?? url.lastPathComponent,
                size: (values?.fileSize).map(Int64.init)
            ))
        }
    }

    func removePendingFile(at index: Int) {
        guard pendingFiles.indices.contains(index) else { return }
        stopSecurityScopedAccessIfOwed(for: pendingFiles.remove(at: index).url)
    }

    func clearPendingFiles() {
        let urls = pendingFiles.map(\.url)
        pendingFiles.removeAll()
        for url in urls { stopSecurityScopedAccessIfOwed(for: url) }
    }

    private func stopSecurityScopedAccessIfOwed(for url: URL) {
        guard let index = securityScopedURLs.firstIndex(of: url) else { return }
        securityScopedURLs.remove(at: index)
        stopSecurityScopedAccess(url)
    }

    func buildImageBlocks(from images: [UIImage], workspaceId: String) async throws
        -> [[String: Any]]? {
        guard !images.isEmpty else { return nil }
        var payloads: [Data] = []
        for (index, image) in images.enumerated() {
            guard let data = image.jpegData(
                compressionQuality: Constants.Conversation.Composer.imageCompressionQuality
            ) else {
                throw ImagePlacementError.encodingFailed(index: index + 1)
            }
            guard data.count <= Self.maxImageReferenceBytes else {
                throw ImagePlacementError.imageTooLarge(index: index + 1)
            }
            payloads.append(data)
        }
        guard payloads.reduce(0, { $0 + $1.count }) <= Self.maxImageReferenceBytes else {
            throw ImagePlacementError.imagesTooLarge
        }

        var blocks: [[String: Any]] = []
        for (index, data) in payloads.enumerated() {
            let placed: AttachmentUploadService.PlacedAttachment
            do {
                placed = try await uploadService.placeData(
                    workspaceId: workspaceId,
                    fileName: "image-\(Int(Date().timeIntervalSince1970 * 1000))-\(index + 1).jpg",
                    data: data,
                    mimeType: "image/jpeg"
                )
            } catch {
                throw ImagePlacementError.placementFailed(index: index + 1, underlying: error)
            }
            blocks.append([
                "type": "image",
                "attachmentId": placed.attachmentId,
                "mimeType": placed.mimeType ?? "image/jpeg"
            ])
        }
        return blocks
    }

    func buildFileBlocks(from files: [PendingFile], workspaceId: String) async throws
        -> [[String: Any]]? {
        guard !files.isEmpty else { return nil }
        for file in files { fileUploadProgress[file.id] = 0 }
        defer { fileUploadProgress.removeAll() }

        var blocks: [[String: Any]] = []
        for file in files {
            if let size = file.size, size > Int64(AttachmentUploadService.maxAttachmentBytes) {
                throw FilePlacementError.fileTooLarge(name: file.displayName)
            }
            let placed: AttachmentUploadService.PlacedAttachment
            do {
                placed = try await uploadService.placeFile(
                    workspaceId: workspaceId,
                    fileName: file.displayName,
                    fileURL: file.url,
                    mimeType: Self.mimeType(for: file.url)
                ) { [weak self] fraction in
                    self?.fileUploadProgress[file.id] = fraction
                }
            } catch AttachmentUploadService.UploadError.payloadTooLarge {
                throw FilePlacementError.fileTooLarge(name: file.displayName)
            } catch {
                throw FilePlacementError.placementFailed(
                    name: file.displayName,
                    underlying: error
                )
            }
            fileUploadProgress[file.id] = 1
            var block: [String: Any] = [
                "type": "file",
                "attachmentId": placed.attachmentId,
                "fileName": placed.fileName,
                "size": placed.size
            ]
            if let mimeType = placed.mimeType { block["mimeType"] = mimeType }
            blocks.append(block)
        }
        return blocks
    }

    static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    func surfaceImagePlacementFailure(
        _ error: Error,
        content: String,
        images: [UIImage]?,
        messageText: inout String
    ) {
        imagePlacementError = error.localizedDescription
        if messageText.isEmpty { messageText = content }
        if let images, pendingImages.isEmpty { pendingImages = images }
    }

    func surfaceFilePlacementFailure(
        _ error: Error,
        content: String,
        images: [UIImage]?,
        messageText: inout String
    ) {
        filePlacementError = error.localizedDescription
        if messageText.isEmpty { messageText = content }
        if let images, pendingImages.isEmpty { pendingImages = images }
    }
}
