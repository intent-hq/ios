import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Classifies and loads picked library videos, which import as files.
struct PhotoLibraryVideos {
    var isVideo: (PhotosPickerItem) -> Bool
    var load: (PhotosPickerItem) async throws -> ImportedPhotoVideo?

    static var live: Self {
        Self(
            isVideo: { item in item.supportedContentTypes.contains { $0.conforms(to: .movie) } },
            load: { item in try await item.loadTransferable(type: ImportedPhotoVideo.self) }
        )
    }
}

extension ConversationAttachmentPipeline {
    var remainingPhotoImageCount: Int? {
        maximumPhotoImageCount.map { max(0, $0 - pendingImages.count) }
    }

    func addImage(_ image: UIImage) { pendingImages.append(image) }

    func startLoadingSelectedPhotos(workspaceId: String) {
        guard photoImportTask == nil, !selectedPhotoItems.isEmpty else { return }
        photoImportTask = Task { [weak self] in
            guard let self else { return }
            await loadSelectedPhotos(workspaceId: workspaceId)
            photoImportTask = nil
            // A new visible composer can select a batch while cancellation of
            // the previous import is unwinding. Do not discard that selection.
            startLoadingSelectedPhotos(workspaceId: workspaceId)
        }
    }

    func cancelPhotoImport() {
        photoImportTask?.cancel()
        selectedPhotoItems.removeAll()
    }

    private func loadSelectedPhotos(workspaceId: String) async {
        guard !isLoadingPhotos, !Task.isCancelled else { return }
        isLoadingPhotos = true
        defer { isLoadingPhotos = false }
        // Consume each batch before suspending. Picker changes can otherwise
        // load a selection twice, or erase another selection made during import.
        while !selectedPhotoItems.isEmpty {
            guard !Task.isCancelled else { return }
            let items = selectedPhotoItems
            selectedPhotoItems.removeAll()
            let imageCount = items.filter { !photoVideos.isVideo($0) }.count
            // Videos never use image slots. A batch with too many images keeps
            // its videos but rejects all of its images, with the limit alert.
            let imagesFit = canImportPhotoImages(imageCount)
            guard imagesFit || imageCount < items.count else { continue }
            if imagesFit, maximumPhotoImageCount != nil {
                imagePlacementError = nil
            }
            var failedImageCount = 0
            for item in items {
                guard !Task.isCancelled else { return }
                if photoVideos.isVideo(item) {
                    await loadVideo(item, workspaceId: workspaceId)
                } else if imagesFit, !(await loadPhotoImage(item)) {
                    failedImageCount += 1
                }
            }
            if failedImageCount > 0 {
                attachmentImportError = Self.photoImportFailureMessage
            }
        }
    }

    /// Returns false only for a transfer or decode failure worth reporting;
    /// cancellation stays silent.
    private func loadPhotoImage(_ item: PhotosPickerItem) async -> Bool {
        guard let data = await loadPhotoData(item), let image = UIImage(data: data) else {
            return Task.isCancelled
        }
        // Paste or another selection can consume capacity while
        // Photos is loading the transferable data.
        if !Task.isCancelled, canImportPhotoImages(1) { pendingImages.append(image) }
        return true
    }

    static let photoImportFailureMessage = "Couldn't add some of the selected photos. Try selecting them again."
    static let fileImportFailureMessage = "Couldn't add some of the selected files. Try selecting them again."

    /// The file importer reports a failure; user cancellation stays silent.
    func reportFileImportFailure(_ error: Error) {
        if (error as? CocoaError)?.code == .userCancelled { return }
        attachmentImportError = Self.fileImportFailureMessage
    }

    private func canImportPhotoImages(_ count: Int) -> Bool {
        guard let maximumPhotoImageCount, let remainingPhotoImageCount else { return true }
        guard count <= remainingPhotoImageCount else {
            imagePlacementError = "You can attach up to \(maximumPhotoImageCount) images. Remove an image before adding more."
            return false
        }
        return true
    }

    func addVideo(_ video: ImportedPhotoVideo, workspaceId: String) throws {
        try Task.checkCancellation()
        guard workspaceId != Workspace.chiefWorkspaceId else {
            throw FilePlacementError.videoUnavailableInAssistant
        }
        pendingFiles.append(PendingFile(
            url: video.url,
            displayName: video.url.lastPathComponent,
            size: Int64(video.size),
            video: video
        ))
    }

    func validateVideos(in files: [PendingFile], workspaceId: String) throws {
        for file in files where file.video != nil || WorkspaceVideo.isVideo(path: file.url.path) {
            guard workspaceId != Workspace.chiefWorkspaceId else {
                throw FilePlacementError.videoUnavailableInAssistant
            }
            // Files can grow after selection. Check disk metadata again before
            // starting any upload, rather than relying only on the picked size.
            var url = file.url
            url.removeAllCachedResourceValues()
            let currentSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let size = max(file.size ?? 0, currentSize.map(Int64.init) ?? 0)
            guard size <= Int64(ImportedPhotoVideo.maxBytes) else { throw ImportedPhotoVideo.ImportError.tooLarge }
        }
    }

    private func loadVideo(_ item: PhotosPickerItem, workspaceId: String) async {
        do {
            guard workspaceId != Workspace.chiefWorkspaceId else {
                throw FilePlacementError.videoUnavailableInAssistant
            }
            let video = try await photoVideos.load(item)
            try Task.checkCancellation()
            guard let video else {
                filePlacementError = "This video could not be loaded from Photos. Please try again."
                return
            }
            try addVideo(video, workspaceId: workspaceId)
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            filePlacementError = error.localizedDescription
        }
    }
}

extension View {
    /// Picked photos/files that failed to load; successful picks stay attached (#463).
    func attachmentImportAlert(_ pipeline: ConversationAttachmentPipeline) -> some View {
        alert(
            "Couldn't Add Attachments",
            isPresented: Binding(
                get: { pipeline.attachmentImportError != nil },
                set: { if !$0 { pipeline.attachmentImportError = nil } }
            ),
            presenting: pipeline.attachmentImportError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { detail in
            Text(detail)
        }
    }
}
