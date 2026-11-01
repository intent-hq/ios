import Foundation
@testable import Intent
import PhotosUI
import SwiftUI
import Testing
import UIKit

/// #861: the ordinary composer's Photos picks share the five-image limit.
extension ConversationViewModelTests {
    @Test func composerPhotoImportsCountPendingImagesAcrossBatches() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let pipeline = viewModel.attachmentPipeline
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let data = try #require(UIImage(systemName: "star")?.pngData())
        var loadedPhotos = 0
        pipeline.loadPhotoData = { _ in
            loadedPhotos += 1
            return data
        }
        #expect(viewModel.remainingPhotoImageCount == limit)
        viewModel.selectedPhotoItems = (0..<limit).map { PhotosPickerItem(itemIdentifier: "first-\($0)") }
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit)
        #expect(viewModel.remainingPhotoImageCount == 0)

        viewModel.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "repeat-batch")]
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit)
        #expect(loadedPhotos == limit, "over-cap selections are rejected before loading")
        #expect(viewModel.imagePlacementError?.contains("up to \(limit) images") == true)

        viewModel.removeImage(at: 0)
        #expect(viewModel.remainingPhotoImageCount == 1)
        viewModel.imagePlacementError = nil
        viewModel.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "replacement")]
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit)
        #expect(loadedPhotos == limit + 1)
        #expect(viewModel.imagePlacementError == nil)
    }

    @Test(.timeLimit(.minutes(1))) func composerPhotoImportRechecksCapacityAfterLoading() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let pipeline = viewModel.attachmentPipeline
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        let data = try #require(image.pngData())
        let (started, didStart) = AsyncStream.makeStream(of: Void.self)
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        defer { didStart.finish(); release.finish() }
        pipeline.loadPhotoData = { _ in
            didStart.yield()
            for await _ in gate { break }
            return data
        }
        viewModel.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "in-flight")]
        viewModel.loadSelectedPhotos()
        let importTask = try #require(pipeline.photoImportTask)
        defer { importTask.cancel() }
        for await _ in started { break }
        for _ in 0..<limit { pipeline.addImage(image) }
        release.yield()
        await importTask.value

        #expect(viewModel.pendingImages.count == limit)
        #expect(viewModel.pendingImages.allSatisfy { $0 === image }, "the late import must not replace existing images")
        #expect(viewModel.imagePlacementError?.contains("up to \(limit) images") == true)
    }

    /// Library videos import as files and never use image slots, so a full
    /// image tray keeps Photos open for videos in workspace conversations.
    @Test func composerPhotosStayAvailableForVideosAtImageLimit() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let pipeline = viewModel.attachmentPipeline
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        #expect(viewModel.photoPickerFilter == .any(of: [.images, .videos]))
        for _ in 0..<limit { pipeline.addImage(image) }

        #expect(viewModel.remainingPhotoImageCount == 0)
        #expect(viewModel.isPhotosPickerEnabled)
        #expect(viewModel.photoPickerFilter == .videos)
        #expect(viewModel.photoPickerMaxSelectionCount == limit)

        let videoDirectory = try await stubPhotoVideos(in: pipeline)
        defer { try? FileManager.default.removeItem(at: videoDirectory) }
        viewModel.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "video-library")]
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit)
        #expect(viewModel.pendingFiles.count == 1)
        #expect(viewModel.pendingFiles.first?.video != nil)
        #expect(viewModel.imagePlacementError == nil)
        #expect(viewModel.filePlacementError == nil)
    }

    @Test func composerMixedPhotoSelectionOverImageSlotsKeepsVideos() async throws {
        let (viewModel, _) = makeFakeBackedVM()
        let pipeline = viewModel.attachmentPipeline
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        for _ in 0..<(limit - 1) { pipeline.addImage(image) }
        #expect(viewModel.photoPickerFilter == .any(of: [.images, .videos]))
        var loadedPhotos = 0
        pipeline.loadPhotoData = { _ in
            loadedPhotos += 1
            return image.pngData()
        }
        let videoDirectory = try await stubPhotoVideos(in: pipeline)
        defer { try? FileManager.default.removeItem(at: videoDirectory) }

        viewModel.selectedPhotoItems = ["image-a", "video-a", "image-b"].map { PhotosPickerItem(itemIdentifier: $0) }
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit - 1, "the batch's images exceed the one remaining slot")
        #expect(loadedPhotos == 0, "over-cap images are rejected before loading")
        #expect(viewModel.pendingFiles.count == 1, "the batch's video still imports")
        #expect(viewModel.imagePlacementError?.contains("up to \(limit) images") == true)

        viewModel.imagePlacementError = nil
        viewModel.selectedPhotoItems = ["image-c", "video-b"].map { PhotosPickerItem(itemIdentifier: $0) }
        viewModel.loadSelectedPhotos()
        await pipeline.photoImportTask?.value
        #expect(viewModel.pendingImages.count == limit)
        #expect(viewModel.pendingFiles.count == 2)
        #expect(viewModel.imagePlacementError == nil)
    }

    /// The Assistant accepts no videos, so its picker stays images-only and
    /// Photos is disabled once the image slots are full.
    @Test func assistantComposerPhotosAreImagesOnlyAndDisabledAtLimit() throws {
        let (viewModel, _) = makeFakeBackedVM(workspaceId: Workspace.chiefWorkspaceId)
        let limit = Constants.Conversation.Composer.maximumImageSelectionCount
        let image = try #require(UIImage(systemName: "star"))
        #expect(viewModel.photoPickerFilter == .images)
        #expect(viewModel.photoPickerMaxSelectionCount == limit)
        for _ in 0..<(limit - 2) { viewModel.attachmentPipeline.addImage(image) }
        #expect(viewModel.photoPickerMaxSelectionCount == 2)
        #expect(viewModel.isPhotosPickerEnabled)
        for _ in 0..<2 { viewModel.attachmentPipeline.addImage(image) }
        #expect(!viewModel.isPhotosPickerEnabled)
        #expect(viewModel.photoPickerMaxSelectionCount == 1, "Photos treats zero as unlimited")
    }

    /// Treats items named `video-…` as library videos backed by a real clip.
    private func stubPhotoVideos(in pipeline: ConversationAttachmentPipeline) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("composer-video-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let bytes = try await IntentFileVideoTests.videoBytes()
        pipeline.photoVideos.isVideo = { $0.itemIdentifier?.hasPrefix("video-") == true }
        pipeline.photoVideos.load = { item in
            let source = directory.appendingPathComponent("\(item.itemIdentifier ?? "clip").mp4")
            try bytes.write(to: source)
            return try await ImportedPhotoVideo.importFile(at: source)
        }
        return directory
    }
}
