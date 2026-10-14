import Foundation
@testable import Intent
import PhotosUI
import SwiftUI
import Testing
import UIKit

/// The visionOS floating composer's lifecycle against a real photo import.
/// A modal merely covering the chat must not cancel a picked photo/video
/// import (it finishes and its attachment is waiting on dismissal); only a
/// genuine withdrawal — navigation, loading, the question slot — cancels it.
@MainActor
struct FloatingComposerImportTests {
    private static let workspaceId = "demo-ws-dashboard"

    /// Starts a one-photo import whose load stays in flight until the
    /// returned continuation is resumed.
    private func startGatedImport(
        in pipeline: ConversationAttachmentPipeline
    ) async throws -> (task: Task<Void, Never>, release: AsyncStream<Void>.Continuation) {
        let (gate, release) = AsyncStream.makeStream(of: Void.self)
        let data = try #require(UIImage(systemName: "photo")?.pngData())
        pipeline.loadPhotoData = { _ in
            for await _ in gate { break }
            return data
        }
        pipeline.selectedPhotoItems = [PhotosPickerItem(itemIdentifier: "in-flight-photo")]
        pipeline.startLoadingSelectedPhotos(workspaceId: Self.workspaceId)
        let task = try #require(pipeline.photoImportTask)
        for _ in 0..<100 where !pipeline.isLoadingPhotos {
            await Task.yield()
        }
        try #require(pipeline.isLoadingPhotos, "the import must be in flight before the host changes")
        return (task, release)
    }

    /// The floating host's contract (FloatingComposerOrnament): it cancels
    /// the chat's photo import (`onWithdraw`) exactly when a presentation
    /// change ends it, and never through the composer merely unmounting.
    @discardableResult
    private func applyFloatingHost(
        from old: FloatingComposerPresentation,
        isActiveChat: Bool,
        isForemost: Bool,
        to pipeline: ConversationAttachmentPipeline
    ) -> FloatingComposerPresentation {
        let new = FloatingComposerPolicy.presentation(
            isActiveChat: isActiveChat,
            isForemost: isForemost,
            showsLoadingState: false,
            composerVisible: true
        )
        if FloatingComposerPolicy.cancelsPhotoImport(from: old, to: new) {
            pipeline.cancelPhotoImport()
        }
        return new
    }

    @Test func coveringModalKeepsAnInFlightPhotoImport() async throws {
        // Regression: the Assistant sheet, an auto-presented question sheet,
        // the model picker or a note sheet covering the chat silently
        // cancelled a photo/video import the user had just picked.
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)

        let covered = applyFloatingHost(from: .shown, isActiveChat: true, isForemost: false, to: pipeline)
        #expect(covered == .covered)
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.count == 1, "the import must finish under the covering modal")
        #expect(!pipeline.isLoadingPhotos)

        // Dismissal reveals the composer with the completed attachment.
        let revealed = applyFloatingHost(from: covered, isActiveChat: true, isForemost: true, to: pipeline)
        #expect(revealed == .shown)
        #expect(pipeline.pendingImages.count == 1)
    }

    @Test func navigatingAwayStillCancelsAnInFlightPhotoImport() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)

        applyFloatingHost(from: .shown, isActiveChat: false, isForemost: true, to: pipeline)
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.isEmpty, "a chat that navigated away must not keep importing")
        #expect(pipeline.selectedPhotoItems.isEmpty)
    }

    @Test func navigatingAwayWhileCoveredCancelsTheImport() async throws {
        // Covered, then the chat itself goes away (e.g. a child agent opens
        // from the Assistant): that is a genuine withdrawal.
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)

        applyFloatingHost(from: .covered, isActiveChat: false, isForemost: false, to: pipeline)
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.isEmpty)
    }

    @Test func revealingOrCoveringNeverCancels() {
        let states: [FloatingComposerPresentation] = [.covered, .shown, .withdrawn]
        for old in states {
            #expect(!FloatingComposerPolicy.cancelsPhotoImport(from: old, to: .covered))
            #expect(!FloatingComposerPolicy.cancelsPhotoImport(from: old, to: .shown))
        }
        #expect(!FloatingComposerPolicy.cancelsPhotoImport(from: .withdrawn, to: .withdrawn))
    }
}
