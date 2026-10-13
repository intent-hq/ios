import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension ConversationAttachmentPipeline {
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
            for item in items {
                guard !Task.isCancelled else { return }
                if item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                    await loadVideo(item, workspaceId: workspaceId)
                } else if let data = await loadPhotoData(item),
                          let image = UIImage(data: data), !Task.isCancelled {
                    pendingImages.append(image)
                }
            }
        }
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
            let video = try await item.loadTransferable(type: ImportedPhotoVideo.self)
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
