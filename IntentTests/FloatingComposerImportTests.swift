import Foundation
@testable import Intent
import PhotosUI
import SwiftUI
import Testing
import UIKit

/// The visionOS floating composer's lifecycle (`FloatingComposerLifecycle`)
/// against a real photo import. A modal merely covering the chat must not
/// cancel a picked photo/video import (it finishes and its attachment is
/// waiting on dismissal); only a genuine withdrawal — navigation, loading,
/// disappearance, or the question slot — cancels it, and at most once.
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

    @Test func coveringModalKeepsAnInFlightPhotoImport() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)
        var lifecycle = FloatingComposerLifecycle()
        lifecycle.appear(isForemost: true, showsLoadingState: false, composerVisible: true)
        #expect(lifecycle.presentation == .shown)

        if lifecycle.sync(isForemost: false, showsLoadingState: false, composerVisible: true) {
            pipeline.cancelPhotoImport()
        }
        #expect(lifecycle.presentation == .covered)
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.count == 1, "the import must finish under the covering modal")
        #expect(!pipeline.isLoadingPhotos)

        if lifecycle.sync(isForemost: true, showsLoadingState: false, composerVisible: true) {
            pipeline.cancelPhotoImport()
        }
        #expect(lifecycle.presentation == .shown)
        #expect(pipeline.pendingImages.count == 1)
    }

    @Test func navigatingAwayStillCancelsAnInFlightPhotoImport() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)
        var lifecycle = FloatingComposerLifecycle()
        lifecycle.appear(isForemost: true, showsLoadingState: false, composerVisible: true)

        if lifecycle.updateActiveChat(false, isForemost: true, showsLoadingState: false, composerVisible: true) {
            pipeline.cancelPhotoImport()
        }
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.isEmpty, "a chat that navigated away must not keep importing")
        #expect(pipeline.selectedPhotoItems.isEmpty)
    }

    @Test func navigatingAwayWhileCoveredCancelsTheImport() async throws {
        let pipeline = ConversationAttachmentPipeline()
        let (task, release) = try await startGatedImport(in: pipeline)
        var lifecycle = FloatingComposerLifecycle()
        lifecycle.appear(isForemost: false, showsLoadingState: false, composerVisible: true)
        #expect(lifecycle.presentation == .covered)

        if lifecycle.updateActiveChat(false, isForemost: false, showsLoadingState: false, composerVisible: true) {
            pipeline.cancelPhotoImport()
        }
        release.yield()
        release.finish()
        await task.value

        #expect(pipeline.pendingImages.isEmpty)
    }

    @Test func disappearFollowedByTrailingPresentationChangeWithdrawsOnce() {
        var lifecycle = FloatingComposerLifecycle()
        lifecycle.appear(isForemost: true, showsLoadingState: false, composerVisible: true)
        var withdrawals = 0

        if lifecycle.disappear() { withdrawals += 1 }
        if lifecycle.applyPresentation(.withdrawn) { withdrawals += 1 }

        #expect(withdrawals == 1, "Disappear followed by onChange(.withdrawn) must not withdraw twice")
        #expect(!lifecycle.isActiveChat)
        #expect(lifecycle.presentation == .withdrawn)
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
