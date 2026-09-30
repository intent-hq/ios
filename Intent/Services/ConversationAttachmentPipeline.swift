import Foundation
import Observation
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

enum ComposerImageRecovery {
    case preserveCurrentSelection
    case restore([UIImage])

    func apply(to pendingImages: inout [UIImage]) {
        guard pendingImages.isEmpty, case let .restore(images) = self else { return }
        pendingImages = images
    }
}

/// Main-actor-owned composer attachment state and send-time placement logic.
/// Security-scoped access begins when a file is added and remains held until
/// removal, clear after a successful send/queue, or deinitialization.
@MainActor
@Observable final class ConversationAttachmentPipeline {
    // This named aggregate limit mirrors the daemon-facing image contract.
    static let maxImageReferenceBytes = 30 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    // Conservative client budgets leave room for base64 and provider context;
    // they are not a guarantee against any provider's total request limit.
    private static let maxOutgoingImageBytes = 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    private static let maxOutgoingImagesBytes = 5 * 1024 * 1024 // swiftlint:disable:this no_magic_numbers
    private static let maxOutgoingPixelSize: CGFloat = 2048
    private static let maximumResizePasses = 3
    private static let compressionQualities: [CGFloat] = [Constants.Conversation.Composer.imageCompressionQuality, 0.6, 0.4] // swiftlint:disable:this no_magic_numbers
    // Date.timeIntervalSince1970 is expressed in seconds.
    private static let millisecondsPerSecond: TimeInterval = 1000

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
                return "Image \(index) is too large to send even after resizing (over 1 MiB as JPEG)."
            case .imagesTooLarge:
                return "The attached images are too large to send together (over 5 MiB total as JPEG)."
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

    var pendingImages: [UIImage] = [] {
        didSet { imageSelectionRevision &+= 1 }
    }
    @ObservationIgnored private(set) var imageSelectionRevision = 0
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

    /// Called only by the native Paste action. Snapshot each image item before
    /// returning to the run loop, while lazy clipboard providers are available.
    func pasteImages() {
        let pasteboard = UIPasteboard.general
        let imageTypes = (pasteboard.types(forItemSet: nil) ?? []).enumerated().compactMap { index, types in
            types.first { UTType($0)?.conforms(to: .image) == true }.map { (index, $0) }
        }
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        guard imageTypes.count <= limit - pendingImages.count else {
            imagePlacementError = "You can attach up to \(limit) images. Remove an image before pasting more."
            return
        }
        guard !imageTypes.isEmpty else {
            imagePlacementError = "Could not read the pasted image. Copy it again or choose it from Photos."
            return
        }
        var images: [UIImage] = []
        var sourceBytes = 0
        for (index, type) in imageTypes {
            guard let data = pasteboard.data(forPasteboardType: type, inItemSet: IndexSet(integer: index))?.first else {
                imagePlacementError = "Could not read the pasted image. Copy it again or choose it from Photos."
                return
            }
            sourceBytes += data.count
            guard sourceBytes <= Self.maxImageReferenceBytes else {
                imagePlacementError = "The pasted images are too large. Copy smaller images or choose them from Photos."
                return
            }
            guard let image = UIImage(data: data) else {
                imagePlacementError = "Could not read the pasted image. Copy it again or choose it from Photos."
                return
            }
            images.append(image)
        }
        // Commit the batch atomically; never silently drop an unreadable item.
        pendingImages.append(contentsOf: images)
        imagePlacementError = nil
    }

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

    /// Only consume this send's selection, not files added while awaiting RPCs.
    func clearPendingFiles(ids: Set<UUID>) {
        let urls = pendingFiles.filter { ids.contains($0.id) }.map(\.url)
        pendingFiles.removeAll { ids.contains($0.id) }
        for url in urls { stopSecurityScopedAccessIfOwed(for: url) }
    }

    /// Keep the captured selection readable even if it is removed from the
    /// composer while another attachment is uploading. These are extra leases,
    /// balanced independently of the composer's own security-scoped access.
    func retainFileAccess(for files: [PendingFile]) -> ConversationSendFileAccess {
        ConversationSendFileAccess(
            urls: files.map(\.url).filter { startSecurityScopedAccess($0) },
            stopAccess: stopSecurityScopedAccess
        )
    }

    private func stopSecurityScopedAccessIfOwed(for url: URL) {
        guard let index = securityScopedURLs.firstIndex(of: url) else { return }
        securityScopedURLs.remove(at: index)
        stopSecurityScopedAccess(url)
    }

    func buildImageBlocks(from images: [UIImage], workspaceId: String) async throws
        -> OutgoingImagePayload {
        guard !images.isEmpty else { return .none }
        var payloads: [Data] = []
        var totalBytes = 0
        for (index, image) in images.enumerated() {
            guard let data = Self.outgoingJPEGData(for: image) else {
                throw ImagePlacementError.encodingFailed(index: index + 1)
            }
            guard data.count <= Self.maxOutgoingImageBytes else {
                throw ImagePlacementError.imageTooLarge(index: index + 1)
            }
            totalBytes += data.count
            guard totalBytes <= Self.maxOutgoingImagesBytes else { throw ImagePlacementError.imagesTooLarge }
            payloads.append(data)
        }

        // The Assistant has no filesystem root for attachment placement (#619).
        // Inline image blocks are a supported protocol arm, not an error fallback.
        if workspaceId == Workspace.chiefWorkspaceId {
            return .inline(payloads.map { data in
                ["type": "image", "data": data.base64EncodedString(), "mimeType": "image/jpeg"]
            })
        }

        var blocks: [[String: Any]] = []
        for (index, data) in payloads.enumerated() {
            let placed: AttachmentUploadService.PlacedAttachment
            do {
                placed = try await uploadService.placeData(
                    workspaceId: workspaceId,
                    fileName: "image-\(Int(Date().timeIntervalSince1970 * Self.millisecondsPerSecond))-\(index + 1).jpg",
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
        return .attachments(blocks)
    }

    /// Bake orientation into bounded pixel dimensions before JPEG encoding.
    /// Never modify the original image retained by the draft/send attempt.
    private static func outgoingJPEGData(for image: UIImage) -> Data? {
        let pixels = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        guard pixels.width.isFinite, pixels.height.isFinite, pixels.width > 0, pixels.height > 0 else { return nil }
        let ratio = min(1, maxOutgoingPixelSize / max(pixels.width, pixels.height))
        if ratio == 1, image.imageOrientation == .up,
           let data = image.jpegData(compressionQuality: Constants.Conversation.Composer.imageCompressionQuality),
           data.count <= maxOutgoingImageBytes { return data }

        var size = CGSize(width: max(1, floor(pixels.width * ratio)), height: max(1, floor(pixels.height * ratio)))
        var lastData: Data?
        for _ in 0..<maximumResizePasses {
            let data: Data? = autoreleasepool {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                let upright = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    image.draw(in: CGRect(origin: .zero, size: size))
                }
                var encoded: Data?
                for quality in compressionQualities {
                    guard let candidate = upright.jpegData(compressionQuality: quality) else { return nil }
                    encoded = candidate
                    if candidate.count <= maxOutgoingImageBytes { return candidate }
                }
                return encoded
            }
            guard let data else { return nil }
            if data.count <= maxOutgoingImageBytes { return data }
            lastData = data
            size = CGSize(width: max(1, floor(size.width / 2)), height: max(1, floor(size.height / 2)))
        }
        // The caller rejects any remaining over-budget data before any RPC.
        return lastData
    }

    func buildFileBlocks(from files: [PendingFile], workspaceId: String) async throws
        -> OutgoingFilePayload {
        guard !files.isEmpty else { return .none }
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
        return .attachments(blocks)
    }

    static func mimeType(for url: URL) -> String? {
        UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
    }

    func surfaceImagePlacementFailure(
        _ error: Error,
        content: String,
        imageRecovery: ComposerImageRecovery,
        messageText: inout String
    ) {
        imagePlacementError = error.localizedDescription
        if messageText.isEmpty { messageText = content }
        imageRecovery.apply(to: &pendingImages)
    }

    func surfaceFilePlacementFailure(
        _ error: Error,
        content: String,
        imageRecovery: ComposerImageRecovery,
        messageText: inout String
    ) {
        filePlacementError = error.localizedDescription
        if messageText.isEmpty { messageText = content }
        imageRecovery.apply(to: &pendingImages)
    }
}
